import Foundation

/// Anything the loop can hand a validated `ToolCall` to.
///
/// `AgentLoop` used to name `ToolRouter` directly, which quietly said "the only
/// things an agent can touch are connectors". The command chord needs the same loop
/// over the user's own notes and reminders as well, so the loop takes the abstraction
/// and the composition happens outside it.
@MainActor
protocol AgentToolRunning {
    func run(_ call: ToolCall) async -> ToolResult
}

extension ToolRouter: AgentToolRunning {}

/// Runs local tools locally and everything else through the connector router, and
/// keeps a record of what actually ran.
///
/// That record is the point. A model that answers *without* calling anything has, for
/// a spoken command, done nothing at all — the words the user dictated would vanish.
/// `executed` is what lets the caller tell "it acted" from "it talked", and fall back
/// to filing a note in the second case.
@MainActor
final class CommandToolRouter: AgentToolRunning {
    private let local: LocalToolRunner
    private let connectors: ToolRouter?

    /// Tool names that reached a runner, in call order.
    private(set) var executed: [String] = []
    /// Side effects the local runner reported, in call order.
    private(set) var effects: [LocalToolRunner.Effect] = []
    /// The last thing a tool said it did. Stands in for the model's report when the
    /// loop acts and then runs out of budget before it can summarise — the action
    /// happened, so the band has to say so rather than pretend the command didn't run.
    private(set) var lastResult: String?

    init(local: LocalToolRunner, connectors: ToolRouter?) {
        self.local = local
        self.connectors = connectors
    }

    func run(_ call: ToolCall) async -> ToolResult {
        executed.append(call.tool)
        let result: ToolResult
        if LocalToolCatalog.names.contains(call.tool) {
            let (local, effect) = await local.run(call)
            if let effect { effects.append(effect) }
            result = local
        } else if let connectors {
            result = await connectors.run(call)
        } else {
            result = .failure("No connector is set up for that yet.")
        }
        if result.ok { lastResult = result.text }
        return result
    }

    /// Whether anything the user would call an action happened — a note or a
    /// reminder created, or a connector write that went through. A read doesn't
    /// count: the answer is the whole of its result.
    var didCreateSomething: Bool {
        effects.contains { effect in
            switch effect {
            case .noteCreated, .reminderCreated: return true
            case .read: return false
            }
        }
    }
}
