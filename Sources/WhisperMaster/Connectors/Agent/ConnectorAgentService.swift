import Foundation

/// Assembles the agent for one question: the user's available tools, a router bound to
/// their connections, and the local model.
///
/// The single entry point for both the spoken day-query path and a scheduled automation,
/// so the two can't drift into different behaviour. The only difference between them is
/// the approval policy: interactive gets the notch card, unattended denies anything
/// without a standing grant.
@MainActor
struct ConnectorAgentService {
    let store: ConnectorInstanceStore
    let approvals: ApprovalCoordinator

    /// Runs the loop and falls back to the deterministic summary when it can't produce
    /// an answer. Returns nil only when the loop is off or unusable, so the caller uses
    /// the deterministic path directly.
    ///
    /// - Parameter unattended: an automation. Writes with no standing grant are denied
    ///   rather than raising a card nobody will see.
    func answer(question: String,
                unattended: Bool = false,
                generate: @escaping AgentLoop.Generate) async -> AgentOutcome? {
        // Writes stay published even unattended: a standing grant the user gave
        // interactively is exactly what makes a scheduled write legitimate. Anything
        // *without* one is denied by the policy below, so publishing them can't create
        // an unapproved write — it only lets an approved one run.
        let tools = ToolRegistry.available(store: store, includeWrites: true)
        guard !tools.isEmpty else { return nil }

        let router = ToolRouter(
            store: store,
            requestApproval: unattended
                ? ApprovalCoordinator.denyUnattended
                : { [approvals] approval in await approvals.request(approval) })

        let loop = AgentLoop(tools: tools, router: router, generate: generate)
        let outcome = await loop.run(question: question)
        return outcome.exhausted ? nil : outcome
    }

    /// The production generator: the already-loaded qwen.
    ///
    /// **Note the cost.** `MlxCleanupService` keeps a persistent KV cache primed on the
    /// *cleanup* system prompt; passing a different system prompt re-prefills it. So an
    /// agent call re-primes, and the next dictation cleanup re-primes back. That's
    /// acceptable here — neither is in the sub-second dictation hot path — but it's the
    /// reason the loop isn't run speculatively or on every transcript.
    static func liveGenerator() -> AgentLoop.Generate {
        { text, systemPrompt in
            await MlxCleanupService.shared.clean(text, systemPrompt: systemPrompt)
        }
    }
}
