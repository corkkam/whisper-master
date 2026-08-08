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

    func run(_ call: ToolCall) async -> ToolResult {
        guard let descriptor = ToolCatalog.descriptor(named: call.tool) else {
            return .failure("No such tool: \(call.tool).")
        }
        if call.tool == "list_connectors" { return listConnectors() }

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
            return await read(capability: capability,
                              from: targets,
                              scopedTo: scoped?.displayLabel,
                              call: call)

        case .write:
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
            // The fan-out runs over exactly the instances resolved above. Passing the
            // store alone here is what made a *named* calendar read merge every
            // calendar while still reporting the one label the user said.
            let day = resolveDay(call.arguments["when"])
            let summary = await DaySummaryService.buildAsync(
                store: store, instances: instances, scopedTo: scopedTo, now: day.date)
            let lines = summary.events.map { event in
                let when = event.isAllDay ? "all day" : Self.time.string(from: event.start)
                let whose = event.instanceLabel.isEmpty ? "" : " [\(event.instanceLabel)]"
                return "\(when) — \(event.title)\(whose)"
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
            return ToolResult(ok: true, text: text, instanceLabels: served)

        case .messages, .tasks, .files, .mail:
            var lines: [String] = []
            var served: [String] = []
            for instance in instances {
                guard let provider = ProviderRegistry.itemProvider(for: instance) else { continue }
                let outcome = await provider.recentItems(for: instance, limit: 15)
                if let error = outcome.error {
                    store.setError(instance.id, error)
                    // Named, not swallowed — a partial answer must admit what's missing.
                    lines.append("[\(instance.displayLabel)] couldn't be read: \(error.message)")
                    continue
                }
                store.setError(instance.id, nil)
                served.append(instance.displayLabel)
                lines += outcome.value.map { item in
                    let detail = item.detail.isEmpty ? "" : " (\(item.detail))"
                    return "\(item.title)\(detail) [\(instance.displayLabel)]"
                }
            }
            let text = lines.isEmpty ? "Nothing to report." : lines.joined(separator: "\n")
            return ToolResult(ok: true, text: text, instanceLabels: served)
        }
    }

    // MARK: - Writes

    private func write(_ call: ToolCall,
                       descriptor: ToolDescriptor,
                       instance: ConnectorInstance) async -> ToolResult {
        guard let provider = ProviderRegistry.provider(for: instance) as? any WriteCapableProvider else {
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

        switch WriteAuthorizer.authorize(tool: descriptor,
                                         instanceID: instance.id,
                                         target: target,
                                         grants: store.grants) {
        case .refused(let reason):
            return .failure(reason)

        case .needsApproval:
            guard let target else { return .failure("No target to approve.") }
            let approval = PendingApproval(
                tool: call.tool,
                instanceID: instance.id,
                instanceLabel: instance.displayLabel,
                target: target,
                arguments: arguments)
            switch await requestApproval(approval) {
            case .denied:
                // Not an error — the user answered. Saying so plainly keeps the model
                // from retrying the same write.
                return ToolResult(ok: false, text: "The user declined that.", instanceLabels: [])
            case .allowedAlways:
                store.addGrant(Grant(tool: call.tool, instanceID: instance.id, target: target))
            case .allowedOnce:
                break
            }

        case .granted:
            break
        }

        let result = await provider.performWrite(
            tool: call.tool, arguments: arguments, instance: instance)
        return ToolResult(ok: result.ok, text: result.summary,
                          instanceLabels: [instance.displayLabel])
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
        guard descriptor.parameters.contains(where: { $0.name == "when" }) else {
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
    private func resolveDay(_ phrase: String?) -> ResolvedDay {
        let today = now()
        guard let phrase, !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let parsed = RelativeTimeParser.parse(phrase, now: today)
        else { return ResolvedDay(date: today, label: "today") }
        return ResolvedDay(date: parsed, label: Self.dayLabel(for: parsed, relativeTo: today))
    }

    /// A day a read covers, with both the mid-sentence spelling ("tomorrow") and the
    /// heading spelling ("Tomorrow") — the result text uses each in a different slot.
    private struct ResolvedDay {
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

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
