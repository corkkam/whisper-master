import Foundation

/// What a spoken command produced, ready for the notch.
struct CommandAgentResult: Equatable, Sendable {
    /// The line the band leads with — the model's own report of what it did.
    let answer: String
    /// The provenance line under it: where the thing went, or what answered.
    let detail: String
    /// SF Symbol for the band, picked from what actually happened rather than from
    /// what the model said it did.
    let icon: String
    /// True when a note or reminder was created, so the confirmation can be tapped
    /// through to Notes & Reminders (and so the caller knows the words landed).
    let createdSomething: Bool
}

/// Runs a spoken command (fn + control) through the reasoning model as an **agent**.
///
/// This is **the** assistant channel — every agent action and every connector
/// conversation arrives here. It assembles one tool set out of two halves — the
/// user's notes and reminders, always, plus their connectors when the assistant is
/// switched on — and lets the model decide what the words were asking for: file a
/// reminder whose time is buried mid-sentence, read the calendar, post a message
/// (which raises the usual approval card), or just answer the question.
///
/// **It returns `nil` rather than guessing**, and the caller then falls back to the
/// deterministic tiers. No model loaded, an exhausted loop, an empty answer, or —
/// the important one — an answer produced **without any tool having executed**. A
/// spoken capture that leaves no artifact is the one outcome the key press has
/// already ruled out: the paste is suppressed, so words that don't land somewhere are
/// words that are gone.
///
/// That last rule is deliberately about *execution*, not about whether the model tried:
/// a tool call that was rejected as malformed leaves `executed` empty too, and an
/// answer written on top of a refusal is ungrounded — the model reporting on data it
/// never received. **Do not relax this to "the model didn't call a tool, so it must
/// have been chatting."** `CommandAgentTests.testAnAnswerWithNoToolCallIsNotAccepted`
/// and `testConnectorToolsAreWithheldUntilTheAssistantIsOptedIn` both pin it, and both
/// catch the relaxation. Conversation through the chord comes from its *tools*, not
/// from letting a 3B improvise.
///
/// A read that executes tools but creates nothing is a different thing and *is*
/// accepted — `createdSomething` false — because the tool output is what it's
/// reporting. The caller sends those to the answer surface.
@MainActor
struct CommandAgentService {
    let store: ConnectorInstanceStore
    let notes: NotesStore
    let approvals: ApprovalCoordinator
    /// Whether the user has opted the assistant into their connectors. Off (the
    /// default) means the chord still reasons — over notes and reminders only.
    var connectorsAllowed: Bool
    var alertStyle: ReminderAlertStyle = .notification
    var soundName: String = ReminderSound.defaultName
    var now: () -> Date = Date.init

    func perform(_ spoken: String,
                 generate: @escaping AgentLoop.Generate) async -> CommandAgentResult? {
        let connectorTools = connectorsAllowed
            ? ToolRegistry.available(store: store, includeWrites: true)
            : []
        // Local first in the list: it's the fallback the prompt names, and a small
        // model biases toward what it read first.
        let tools = LocalToolCatalog.all + connectorTools

        let connectorRouter = connectorTools.isEmpty
            ? nil
            : ToolRouter(store: store,
                         requestApproval: { [approvals] approval in await approvals.request(approval) })
        let router = CommandToolRouter(
            local: LocalToolRunner(notes: notes, alertStyle: alertStyle,
                                   soundName: soundName, now: now),
            connectors: connectorRouter)

        var loop = AgentLoop(tools: tools, router: router, generate: generate)
        loop.prompt = AgentPrompt.command(toolList:)
        loop.now = now
        let outcome = await loop.run(question: spoken)

        guard !router.executed.isEmpty else { return nil }
        // An exhausted loop that already *created* something is not a failure to hand
        // back to the caller — the reminder exists. Falling through to the
        // deterministic path there would file the same words a second time and caption
        // it "Note saved", which is two lies about one command. So the tool's own
        // report stands in for the summary the model ran out of budget to write.
        let answer: String
        if outcome.exhausted {
            guard router.didCreateSomething, let reported = router.lastResult else { return nil }
            answer = reported
        } else {
            answer = outcome.answer
        }
        // Nothing to show and nothing filed is the same as not having run.
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return CommandAgentResult(
            answer: answer,
            detail: detailLine(for: router, outcome: outcome),
            icon: icon(for: router),
            createdSomething: router.didCreateSomething)
    }

    /// The second line: where it went, or who answered. Local writes name the app's
    /// own surface; anything a connector served names the connections, the same
    /// provenance rule the day-summary band follows.
    private func detailLine(for router: CommandToolRouter, outcome: AgentOutcome) -> String {
        if router.didCreateSomething { return "Saved to Notes & Reminders" }
        let labels = Set(outcome.instanceLabels).sorted()
        if !labels.isEmpty { return "From \(labels.joined(separator: ", "))" }
        return "On-device assistant"
    }

    private func icon(for router: CommandToolRouter) -> String {
        for effect in router.effects {
            switch effect {
            case .reminderCreated: return "bell.badge.fill"
            case .noteCreated: return "note.text"
            case .read: continue
            }
        }
        return "sparkles"
    }
}
