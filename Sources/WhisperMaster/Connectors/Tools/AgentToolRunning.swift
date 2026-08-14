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
    /// What a call actually did.
    ///
    /// A superset of `LocalToolRunner.Effect`, because that enum only ever describes
    /// the user's own store and a connector write — a message that went out, an event
    /// that landed on a calendar — is the other thing a spoken command can leave
    /// behind. There used to be no case for it at all, so a Slack send left
    /// `didCreateSomething` false and an exhausted loop reported nothing had happened
    /// about a message that had in fact been sent.
    enum Effect: Equatable, Sendable {
        case local(LocalToolRunner.Effect)
        /// A `.write` tool that reached a connector and came back ok, with the
        /// connections that served it.
        case connectorWrite(tool: String, instanceLabels: [String])
    }

    private let local: LocalToolRunner
    private let connectors: (any AgentToolRunning)?
    /// Injected so a call's duration is fixed under test rather than measured against
    /// the wall clock.
    private let now: () -> Date

    /// Tool names that reached a runner, in call order.
    private(set) var executed: [String] = []
    /// Side effects the calls reported, in call order.
    private(set) var effects: [Effect] = []
    /// The full record of every call — arguments, the connections that served it, what
    /// came back, how long it took.
    ///
    /// `executed` answers "did it act", which is all the *routing* decision needs.
    /// This answers "what did it actually do", which is what the Traces surface needs,
    /// and it lives here for the same reason `executed` does: this is the one point
    /// every call funnels through, so a journal kept anywhere else could drift from it.
    private(set) var journal: [ToolCallTrace] = []
    /// Connections that were asked and couldn't answer, in call order and named once.
    ///
    /// The gap is already in the text the model read, but the model is exactly the
    /// component that can decide not to mention it — and with the paste suppressed, a
    /// run whose only source failed would otherwise report an empty day. The caller
    /// states it in the provenance line instead of trusting the summary.
    private(set) var unreadable: [String] = []
    /// The last thing a tool said it did. Stands in for the model's report when the
    /// loop acts and then runs out of budget before it can summarise — the action
    /// happened, so the band has to say so rather than pretend the command didn't run.
    private(set) var lastResult: String?

    /// - Parameter connectors: the connector router, or nil when the assistant isn't
    ///   opted into them. Taken as the protocol rather than `ToolRouter` so a test can
    ///   stand in for it — no provider can complete a real write under `swift test`.
    init(local: LocalToolRunner,
         connectors: (any AgentToolRunning)?,
         now: @escaping () -> Date = Date.init) {
        self.local = local
        self.connectors = connectors
        self.now = now
    }

    func run(_ call: ToolCall) async -> ToolResult {
        executed.append(call.tool)
        let started = now()
        let result: ToolResult
        if LocalToolCatalog.names.contains(call.tool) {
            let (local, effect) = await local.run(call)
            if let effect { effects.append(.local(effect)) }
            result = local
        } else if let connectors {
            result = await connectors.run(call)
            // Only a write that came back ok is an effect: a denied approval or a
            // provider error is a call that reached the connector and changed nothing.
            if result.ok, ToolCatalog.descriptor(named: call.tool)?.access == .write {
                effects.append(.connectorWrite(tool: call.tool,
                                               instanceLabels: result.instanceLabels))
            }
        } else {
            result = .failure("No connector is set up for that yet.")
        }
        for label in result.unreadable where !unreadable.contains(label) {
            unreadable.append(label)
        }
        // The approval wait is taken out of the call's own duration rather than left
        // in it: a write that sat a minute on the consent card reads as a minute of
        // provider latency otherwise, which is the wrong thing to go and investigate.
        let elapsed = Int((now().timeIntervalSince(started) * 1000).rounded())
        journal.append(ToolCallTrace(
            tool: call.tool,
            arguments: call.arguments,
            connectors: result.instanceLabels,
            ok: result.ok,
            result: TraceText.clamp(result.text),
            milliseconds: max(elapsed - result.approvalMilliseconds, 0),
            approvalMilliseconds: result.approvalMilliseconds,
            authorization: result.authorization))
        if result.ok { lastResult = result.text }
        return result
    }

    /// Whether anything the user would call an action happened — a note or a
    /// reminder created, or a connector write that went through. A read doesn't
    /// count: the answer is the whole of its result.
    var didCreateSomething: Bool {
        effects.contains { effect in
            switch effect {
            case .local(.noteCreated), .local(.reminderCreated), .connectorWrite: return true
            case .local(.read): return false
            }
        }
    }
}
