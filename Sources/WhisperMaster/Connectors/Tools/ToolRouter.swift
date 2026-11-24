import Foundation

/// The result of one tool call, as text the model reads back.
///
/// Every result **names the connection that served it** — openworker stamps
/// `{"account": id, …}` for the same reason. Once more than one connector can answer a
/// question, a result that doesn't say which one answered makes the transcript
/// unauditable, and a user can't tell whether "3 events" came from Work or Personal.
struct ToolResult: Equatable, Sendable {
    let ok: Bool
    let text: String
    /// Labels of the connections that contributed.
    let instanceLabels: [String]
    /// How a write was permitted. nil for a read, and for a write refused before any
    /// card could be raised — there was nothing to authorize.
    var authorization: ToolAuthorization?
    /// How long the call spent waiting on the approval card. Reported separately so
    /// the journal can take it back out of the call's own duration: the user's
    /// thinking time is not the connector's latency.
    var approvalMilliseconds: Int = 0
    /// Connections that were asked and couldn't answer. Named here as well as in the
    /// text so the answer's provenance can state the gap without re-reading the model's
    /// prose — "couldn't look" and "nothing scheduled" mean opposite things, and only
    /// one of them is safe to report as "Nothing to report".
    var unreadable: [String] = []
    /// The loop stops after this result and takes its text as the answer. Set by a
    /// call that started work which finishes elsewhere (`delegate_task`), so the 30 s
    /// budget does not wait for it.
    var endsTurn = false

    static func failure(_ text: String) -> ToolResult {
        ToolResult(ok: false, text: text, instanceLabels: [])
    }
}

/// Dispatches a validated `ToolCall` to the right provider on the right instance.
///
/// Three things happen here and nowhere else: resolving the `connector` argument to an
/// instance, enforcing write authorization, and stamping results with provenance.
@MainActor
struct ToolRouter {
    let store: ConnectorInstanceStore
    /// Raises an approval card and waits. Injected so the router is testable and so a
    /// caller without a notch (a test, the snapshot renderer) can supply a policy
    /// instead of a UI.
    let requestApproval: (PendingApproval) async -> ApprovalOutcome
    /// Injected so a `when` phrase ("tomorrow", "next monday") resolves against a
    /// fixed clock in tests rather than the wall clock.
    var now: () -> Date = Date.init
    /// Set once a connector read has come back ok, and never cleared: see
    /// `WriteAuthorizer.authorize(tainted:)`. A box because `run` is non-mutating.
    /// `CommandAgentService.run` builds one per run and hands the same box to the
    /// `LocalToolRunner`, so a `read_selection` taints the run too, and the flag
    /// cannot leak into the next command.
    var taint = Taint()
    /// The provider that performs a write. Injected so a test can stand in for the
    /// network.
    var writeProvider: (ConnectorInstance) -> (any WriteCapableProvider)? = {
        ProviderRegistry.provider(for: $0) as? any WriteCapableProvider
    }
    /// The rows this run's listings numbered (`ItemTools`). A box, like `taint`, and
    /// one per router, which `CommandAgentService` builds once per run.
    var handles = ItemHandles()
    /// The spoken command: `send_mail` may send to an address the user said.
    var spoken = ""
    /// The provider that serves a listing, a search or an open. Injected so a test can
    /// stand in for the network.
    var itemProvider: (ConnectorInstance) -> (any ItemReadingProvider)? = {
        ProviderRegistry.itemProvider(for: $0)
    }

    /// What a write stopped by a cancel (Escape, sign-out) reports. Nothing was sent.
    static let stoppedBeforeWrite = "Stopped before it ran, so nothing was sent."

    func run(_ call: ToolCall) async -> ToolResult {
        guard let descriptor = ToolCatalog.descriptor(named: call.tool) else {
            return .failure("No such tool: \(call.tool).")
        }
        if call.tool == "list_connectors" { return listConnectors() }
        if let result = await runItemTool(call, descriptor: descriptor) { return result }

        guard let capability = descriptor.capability else {
            return .failure("\(call.tool) isn't wired up.")
        }

        let named = call.arguments[ToolDescriptor.instanceArgument]
        let candidates = store.readable(providing: capability)
        guard !candidates.isEmpty else {
            return .failure("No connector is set up for that yet.")
        }

        switch descriptor.access {
        case .local:
            // Local tools never come here — `CommandToolRouter` runs them itself, and
            // this router is only ever built over connector tools. Failing plainly
            // beats a silent no-op if a future caller wires one in by mistake.
            return .failure("\(call.tool) doesn't run on a connector.")

        case .read:
            // Unqualified reads merge; a named one narrows. This is the addressing rule
            // the whole design turns on.
            let scoped = named.flatMap { ConnectorLabelMatcher.match($0, in: candidates) }
            let targets = scoped.map { [$0] } ?? candidates
            let result = await read(capability: capability,
                                    from: targets,
                                    scopedTo: scoped?.displayLabel,
                                    call: call)
            if result.ok {
                taint.isSet = true
                taint.outsideSelection = true
            }
            return result

        case .write:
            if CalendarTools.editNames.contains(call.tool) {
                return await editEvent(call, descriptor: descriptor, named: named, candidates: candidates)
            }
            // Unqualified writes use the kind default and say which one — never merge,
            // never guess silently.
            let instance = named
                .flatMap { ConnectorLabelMatcher.match($0, in: candidates) }
                ?? defaultWriteTarget(from: candidates)
            guard let instance else { return .failure("No connector to write to.") }
            return await write(call, descriptor: descriptor, instance: instance)
        }
    }

    // MARK: - Reads

    private func read(capability: ConnectorCapability,
                      from instances: [ConnectorInstance],
                      scopedTo: String?,
                      call: ToolCall) async -> ToolResult {
        switch capability {
        case .events:
            if call.tool == CalendarTools.findFreeSlots.name {
                return await freeSlots(call, from: instances, scopedTo: scopedTo)
            }
            // The fan-out runs over exactly the instances resolved above. Passing the
            // store alone here is what made a *named* calendar read merge every
            // calendar while still reporting the one label the user said.
            let day = resolveDay(call.arguments["when"])
            let summary = await DaySummaryService.buildAsync(
                store: store, instances: instances, scopedTo: scopedTo, now: day.date)
            let lines = summary.events.map { event in
                let when = event.isAllDay ? "all day" : Self.time.string(from: event.start)
                let whose = event.instanceLabel.isEmpty ? "" : " [\(event.instanceLabel)]"
                return "\(when) — \(Self.oneLine(event.title))\(whose)"
            }
            // Gaps are named rather than read as an empty day: "couldn't look" and
            // "nothing scheduled" mean opposite things.
            let gaps = summary.gaps.map { "[\($0.instanceLabel)] couldn't be read: \($0.reason.message)" }
            let body = (lines + gaps).joined(separator: "\n")
            let text = body.isEmpty
                ? "Nothing on the calendar \(day.label)."
                : "\(day.heading):\n\(body)"
            // Only the instances that actually contributed, so provenance can't claim
            // an account that failed or was never asked.
            let served = instances
                .filter { instance in !summary.gaps.contains { $0.instanceLabel == instance.displayLabel } }
                .map(\.displayLabel)
            return ToolResult(ok: true, text: text, instanceLabels: served,
                              unreadable: summary.gaps.map(\.instanceLabel))

        case .messages, .tasks, .files, .mail:
            var lines: [String] = []
            var served: [String] = []
            var unreadable: [String] = []
            let numbered = ItemTools.numberedListings.contains(call.tool)
            var found = 0
            for instance in instances {
                guard let provider = itemProvider(instance) else { continue }
                let outcome: ProviderReadOutcome<[ConnectorItem]>
                if call.tool == ItemTools.searchMail {
                    guard found < ItemTools.searchLimit else { break }
                    outcome = await (provider as? any ItemSearchingProvider)?
                        .searchItems(call.arguments["query"] ?? "", for: instance,
                                     limit: ItemTools.searchLimit - found)
                        ?? ProviderReadOutcome([])
                } else {
                    outcome = await provider.recentItems(for: instance, limit: 15)
                }
                found += outcome.value.count
                // A read cut by a cancel says nothing about the connection, so it
                // marks no error on it.
                if let error = outcome.error {
                    if !Task.isCancelled { store.setError(instance.id, error) }
                    // Named, not swallowed — a partial answer must admit what's missing.
                    lines.append("[\(instance.displayLabel)] couldn't be read: \(error.message)")
                    unreadable.append(instance.displayLabel)
                    continue
                }
                if !Task.isCancelled { store.setError(instance.id, nil) }
                served.append(instance.displayLabel)
                lines += outcome.value.map { item in
                    let parts = (item.isUnread ? ["unread"] : [])
                        + (item.detail.isEmpty ? [] : [Self.oneLine(item.detail)])
                    let detail = parts.isEmpty ? "" : " (\(parts.joined(separator: " · ")))"
                    // The number the row tools take; the real ids stay in `handles`.
                    let row = numbered
                        ? "\(handles.add(item, instanceID: instance.id, capability: capability)). " : ""
                    return "\(row)\(Self.oneLine(item.title))\(detail) [\(instance.displayLabel)]"
                }
            }
            let text = lines.isEmpty ? "Nothing to report." : lines.joined(separator: "\n")
            return ToolResult(ok: true, text: text, instanceLabels: served,
                              unreadable: unreadable)

        case .tools:
            // No catalog tool reads this: an MCP server's tools run through `MCPToolRunner`.
            return .failure("\(call.tool) doesn't run on an MCP server.")
        }
    }

    // MARK: - Writes

    func write(_ call: ToolCall,
               descriptor: ToolDescriptor,
               instance: ConnectorInstance) async -> ToolResult {
        guard let provider = writeProvider(instance) else {
            return .failure("\(instance.displayLabel) can't be written to.")
        }
        // A tool whose target *is* the connection (a calendar event goes to a
        // calendar, full stop) can be called without naming one — the default write
        // target resolved it above. Bind the grant to that connection's label rather
        // than refusing a call the user's own words never needed to qualify.
        let target = call.target(for: descriptor)
            ?? (descriptor.targetArg == ToolDescriptor.instanceArgument ? instance.displayLabel : nil)

        // Resolve a spoken `when` into concrete times **before** the approval card, so
        // the card states the real time the user is agreeing to rather than the phrase
        // the model echoed, and so both calendar providers receive one already-decided
        // window instead of each parsing English.
        let arguments: [String: String]
        switch resolveWriteTimes(call.arguments, descriptor: descriptor) {
        case .failure(let message): return .failure(message)
        case .success(let resolved): arguments = resolved
        }

        let authorization: ToolAuthorization
        /// The card's own wall time, kept out of the call's. Measured on the injected
        /// clock like every other duration here, so a test can wind it forward.
        var waited = 0
        let grantable = CalendarTools.grantable(call.tool) && ItemTools.grantable(call.tool)

        switch WriteAuthorizer.authorize(tool: descriptor,
                                         instanceID: instance.id,
                                         target: target,
                                         grants: store.grants,
                                         tainted: taint.isSet) {
        case .refused(let reason):
            return .failure(reason)

        case .needsApproval, .granted where !grantable:
            guard let target else { return .failure("No target to approve.") }
            // A stopped run raises no card.
            guard !Task.isCancelled else { return .failure(Self.stoppedBeforeWrite) }
            let approval = PendingApproval(
                tool: call.tool,
                instanceID: instance.id,
                instanceLabel: instance.displayLabel,
                target: target,
                arguments: arguments,
                grantOffered: !taint.isSet,
                grantable: grantable,
                readSelectionOnly: taint.isSet && !taint.outsideSelection)
            let askedAt = now()
            let outcome = await requestApproval(approval)
            waited = Int(now().timeIntervalSince(askedAt) * 1000)
            switch outcome {
            case .denied:
                // Not an error — the user answered. Saying so plainly keeps the model
                // from retrying the same write.
                return ToolResult(ok: false, text: "The user declined that.",
                                  instanceLabels: [], authorization: .denied,
                                  approvalMilliseconds: waited)
            case .timedOut:
                // Worded apart from a denial because nobody said no: the card was up
                // and went unanswered. Reporting the user's decision here would be the
                // app answering for them, and it hides a card shown where nobody
                // looked.
                return ToolResult(ok: false,
                                  text: "Nobody answered the approval card in time, "
                                      + "so nothing was sent.",
                                  instanceLabels: [], authorization: .timedOut,
                                  approvalMilliseconds: waited)
            case .allowedAlways where taint.isSet || !grantable:
                // The card hides Always in a tainted run and for an edit, so only a
                // caller that ignores `offersAlways` gets here. A grant would outlast the card for a target
                // planted text may have chosen, so this runs once and stores nothing.
                // Mail send hides Always too, and never stores a grant either.
                authorization = .allowedOnce
            case .allowedAlways:
                store.addGrant(Grant(tool: call.tool, instanceID: instance.id, target: target))
                authorization = .allowedAlways
            case .allowedOnce:
                authorization = .allowedOnce
            }

        case .granted:
            authorization = .standingGrant
        }

        // Checked again after the card: a cancel that arrived while it waited (Escape,
        // sign-out) stops the write even if the card was answered Once.
        guard !Task.isCancelled else {
            return ToolResult(ok: false, text: Self.stoppedBeforeWrite, instanceLabels: [],
                              approvalMilliseconds: waited)
        }
        // Its own task, so a cancel cannot cut a request already on the wire: the
        // server may have taken it, and the receipt must then say it was sent.
        let result = await Task {
            if let edit = CalendarEdit(tool: call.tool, arguments: arguments),
               let editor = provider as? any CalendarEditingProvider {
                return await editor.performEdit(edit, instance: instance)
            }
            return await provider.performWrite(tool: call.tool, arguments: arguments, instance: instance)
        }.value
        return ToolResult(ok: result.ok, text: result.summary,
                          instanceLabels: [instance.displayLabel],
                          authorization: authorization,
                          approvalMilliseconds: waited)
    }

    /// Turn a write tool's spoken `when` into concrete `start`/`end` ISO-8601 times.
    ///
    /// A rule rather than a per-tool special case: any write declaring a `when`
    /// parameter gets this treatment. Providers then never parse English — they
    /// receive one already-decided window, which is also what stops the Google and
    /// EventKit calendars from disagreeing about what "friday morning" meant.
    ///
    /// An unparseable phrase **fails the call** rather than defaulting to now.
    /// `RelativeTimeParser` returns nil precisely when the time wasn't clearly
    /// stated, and a meeting silently filed at the wrong hour is the one outcome
    /// worse than the model being told to try again.
    private func resolveWriteTimes(_ arguments: [String: String],
                                   descriptor: ToolDescriptor) -> ResolvedArguments {
        // An optional `when` (`update_calendar_event`) is resolved by its own branch.
        guard descriptor.parameters.contains(where: { $0.name == "when" && $0.isRequired }) else {
            return .success(arguments)
        }
        guard let phrase = arguments["when"], !phrase.isEmpty else {
            return .failure("\(descriptor.name) needs \"when\".")
        }
        guard let start = RelativeTimeParser.parse(phrase, now: now()) else {
            return .failure("Couldn't work out a time from \u{201C}\(phrase)\u{201D}. "
                + "Say it as a clear time, like \u{201C}tomorrow at 3pm\u{201D}.")
        }
        let minutes = arguments["duration_minutes"].flatMap(Int.init) ?? Self.defaultEventMinutes
        // A zero or negative duration would create an instantaneous event, which most
        // calendars render as an all-day blob rather than rejecting.
        let span = max(minutes, 1)
        var resolved = arguments
        resolved["start"] = ConnectorHTTP.iso8601(from: start)
        resolved["end"] = ConnectorHTTP.iso8601(from: start.addingTimeInterval(TimeInterval(span * 60)))
        return .success(resolved)
    }

    private static let defaultEventMinutes = 30

    /// Normalised write arguments, or the line the model is told to correct.
    /// A plain enum rather than `Result` because the failure is a sentence for a
    /// language model, not a thrown error anything up the stack handles.
    private enum ResolvedArguments {
        case success([String: String])
        case failure(String)
    }

    /// The kind default among the candidates, so an unqualified write is deterministic.
    ///
    /// **Write-capable candidates come first.** A `.events` fan-out includes every
    /// calendar instance, but only some of them can be written to; picking the kind
    /// default blindly meant "put it in my calendar" failed with "X can't be written
    /// to" whenever the default happened to be a read-only connection, even though a
    /// perfectly good writable one was sitting next to it.
    private func defaultWriteTarget(from candidates: [ConnectorInstance]) -> ConnectorInstance? {
        let writable = candidates.filter { ProviderRegistry.provider(for: $0) is any WriteCapableProvider }
        let pool = writable.isEmpty ? candidates : writable
        for kind in Set(pool.map(\.kind)) {
            if let hit = store.defaultInstance(of: kind), pool.contains(where: { $0.id == hit.id }) {
                return hit
            }
        }
        return pool.first
    }

    // MARK: - Dates

    /// Resolve an optional spoken `when` phrase to the day a read covers.
    ///
    /// The model is asked for the user's own words ("tomorrow", "next monday") rather
    /// than a date — the same rule `create_reminder` already follows, because a 3B
    /// asked for a calendar date invents plausible, wrong ones. An unparseable phrase
    /// falls back to today rather than failing the call: the user asked about their
    /// calendar either way, and a wrong-day answer is worse than a today answer that
    /// says which day it is.
    func resolveDay(_ phrase: String?) -> ResolvedDay {
        let today = now()
        guard let phrase, !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let parsed = RelativeTimeParser.parse(phrase, now: today)
        else { return ResolvedDay(date: today, label: "today") }
        return ResolvedDay(date: parsed, label: Self.dayLabel(for: parsed, relativeTo: today))
    }

    /// A day a read covers, with both the mid-sentence spelling ("tomorrow") and the
    /// heading spelling ("Tomorrow") — the result text uses each in a different slot.
    struct ResolvedDay {
        let date: Date
        let label: String
        var heading: String { label.prefix(1).uppercased() + label.dropFirst() }
    }

    /// "today" / "tomorrow" / "Monday 4 August" — so a listing always says which day
    /// it is describing, which matters the moment `when` can move it off today.
    private static func dayLabel(for date: Date, relativeTo reference: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: reference) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: reference),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: reference),
           calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        return day.string(from: date)
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        return formatter
    }()

    // MARK: - list_connectors

    private func listConnectors() -> ToolResult {
        let rows = store.ordered.map { instance -> String in
            var flags: [String] = []
            if store.isDefault(instance.id) { flags.append("default") }
            if !instance.isEnabled { flags.append("paused") }
            if let error = instance.lastError { flags.append(error.rawValue) }
            let suffix = flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))"
            return "\(instance.displayLabel) — \(instance.kind.displayName), \(instance.identity)\(suffix)"
        }
        let text = rows.isEmpty ? "No connectors are set up." : rows.joined(separator: "\n")
        return ToolResult(ok: true, text: text, instanceLabels: store.ordered.map(\.displayLabel))
    }

    /// One row is one line: a chat or mail preview can carry line breaks, and
    /// `ToolResultReducer` counts and cuts by line.
    nonisolated static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

/// A run's taint flag. Copies of the router share it, which is right: a copy still
/// serves the same run. Shared with `LocalToolRunner` for the same reason.
@MainActor
final class Taint {
    var isSet = false
    /// Set by every untrusted source except this run's own `read_selection`: a
    /// connector read, or the taint a follow-up inherits. A draft that would type
    /// such text into the user's app is copy only (`AgentDraft.stage`); a rewrite of
    /// the selection typed back over it is not.
    var outsideSelection = false
}
