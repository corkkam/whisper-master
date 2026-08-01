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
    /// headless run (an automation) can supply a policy instead of a UI.
    let requestApproval: (PendingApproval) async -> ApprovalOutcome

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
            let targets = named.flatMap { label in
                ConnectorLabelMatcher.match(label, in: candidates).map { [$0] }
            } ?? candidates
            return await read(capability: capability, from: targets)

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
                      from instances: [ConnectorInstance]) async -> ToolResult {
        switch capability {
        case .events:
            let summary = await DaySummaryService.buildAsync(store: store)
            let lines = summary.events.map { event in
                let when = event.isAllDay ? "all day" : Self.time.string(from: event.start)
                let whose = event.instanceLabel.isEmpty ? "" : " [\(event.instanceLabel)]"
                return "\(when) — \(event.title)\(whose)"
            }
            let text = lines.isEmpty ? "Nothing on the calendar today." : lines.joined(separator: "\n")
            return ToolResult(ok: true, text: text,
                              instanceLabels: instances.map(\.displayLabel))

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
        let target = call.target(for: descriptor)

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
                arguments: call.arguments)
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
            tool: call.tool, arguments: call.arguments, instance: instance)
        return ToolResult(ok: result.ok, text: result.summary,
                          instanceLabels: [instance.displayLabel])
    }

    /// The kind default among the candidates, so an unqualified write is deterministic.
    private func defaultWriteTarget(from candidates: [ConnectorInstance]) -> ConnectorInstance? {
        for kind in Set(candidates.map(\.kind)) {
            if let hit = store.defaultInstance(of: kind), candidates.contains(where: { $0.id == hit.id }) {
                return hit
            }
        }
        return candidates.first
    }

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
