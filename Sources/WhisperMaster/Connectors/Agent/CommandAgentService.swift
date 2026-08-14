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
    /// True when the command left an artifact — a note or reminder filed, or a
    /// connector write that went through — so the band is a receipt rather than an
    /// answer (and so the caller knows the words landed).
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
    /// Hand this capture's recording to a note the agent files, or nil to file
    /// without one. Consumed at most once per capture.
    var takeNoteAudio: (UUID) -> NoteAudio? = { _ in nil }

    /// A run of the agent, result **and** the record of how it got there.
    ///
    /// `perform` returns only the result, and `nil` erases every interesting thing
    /// about a failure: which tools the model was even offered, what it called, what
    /// came back, and which of the four decline rules fired. That was invisible
    /// everywhere — the user saw their question filed as a note and had nothing to
    /// read. So the run is the real return value and `perform` is a thin wrapper over
    /// it for the callers that only want the outcome.
    struct Run: Sendable {
        let result: CommandAgentResult?
        /// Tools the model was offered, in prompt order.
        let toolsOffered: [String]
        let connectorsAllowed: Bool
        let calls: [ToolCallTrace]
        /// What the model itself emitted, and what the loop said back — the half of
        /// the run `calls` cannot show. A model that spent every iteration on
        /// malformed JSON journals no calls at all, and read as "it answered without
        /// calling a tool" until this was carried out of the loop.
        let turns: [TraceTurn]
        /// Why there is no result, or empty when there is one. One of the four decline
        /// rules in this type's doc comment, in words.
        let declineReason: String
    }

    /// - Parameter onStep: called as the loop moves, so the band can name the
    ///   connector it's waiting on. The caller owns the `AppState` write, per the
    ///   "view model is the only writer" rule.
    func perform(_ spoken: String,
                 generate: @escaping AgentLoop.Generate,
                 onStep: @escaping (AgentActivity) -> Void = { _ in }) async -> CommandAgentResult? {
        await run(spoken, generate: generate, onStep: onStep).result
    }

    func run(_ spoken: String,
             generate: @escaping AgentLoop.Generate,
             onStep: @escaping (AgentActivity) -> Void = { _ in }) async -> Run {
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
            local: LocalToolRunner(
                notes: notes, alertStyle: alertStyle, soundName: soundName, now: now,
                // The capture's own words and audio, so a note the agent files keeps
                // what was actually said next to the model's rewrite of it.
                voice: .init(transcript: spoken, takeAudio: takeNoteAudio)),
            connectors: connectorRouter,
            now: now)

        var loop = AgentLoop(tools: tools, router: router, generate: generate)
        loop.prompt = AgentPrompt.command(toolList:)
        loop.now = now
        loop.onStep = onStep
        let outcome = await loop.run(question: spoken)

        /// Every exit reports through this, so a decline can't leave the trace empty —
        /// the same shape `SessionAccounting` uses to make an unaccounted exit
        /// impossible.
        func run(_ result: CommandAgentResult?, _ declineReason: String = "") -> Run {
            Run(result: result,
                toolsOffered: tools.map(\.name),
                connectorsAllowed: connectorsAllowed,
                calls: router.journal,
                turns: Self.traceTurns(outcome.turns),
                declineReason: result == nil ? declineReason : "")
        }

        guard !router.executed.isEmpty else {
            return run(nil, tools.isEmpty
                ? "No tools were available, so there was nothing the assistant could do."
                : "The model answered without calling a tool, so nothing was acted on "
                    + "and the words were filed instead.")
        }
        // An exhausted loop that already *created* something is not a failure to hand
        // back to the caller — the reminder exists, or the message went out. Falling
        // through to the deterministic path there would file the same words a second
        // time and caption it "Note saved", which is two lies about one command. So
        // the tool's own report stands in for the summary the model ran out of budget
        // to write.
        let answer: String
        if outcome.exhausted {
            guard router.didCreateSomething, let reported = router.lastResult else {
                return run(nil, "The model ran out of time or steps before it could "
                    + "report back, and nothing had been created.")
            }
            answer = reported
        } else {
            answer = outcome.answer
        }
        // Nothing to show and nothing filed is the same as not having run.
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return run(nil, "The model returned an empty answer.")
        }

        return run(CommandAgentResult(
            answer: answer,
            detail: Self.detailLine(effects: router.effects,
                                    served: outcome.instanceLabels,
                                    unreadable: router.unreadable),
            icon: icon(for: router),
            createdSomething: router.didCreateSomething))
    }

    /// The loop's transcript, ready to store: the model's own turns and the loop's
    /// replies to them, clamped.
    ///
    /// Tool turns are dropped — their text is already journalled in `calls`, and a
    /// trace that keeps every result twice is what `TraceText.clamp` exists to stop.
    private static func traceTurns(_ turns: [AgentTurn]) -> [TraceTurn] {
        turns
            .filter { $0.role != .tool }
            .map { TraceTurn(role: $0.role.rawValue, text: TraceText.clamp($0.text)) }
    }

    /// The second line: where it went, or who answered, plus any connection that
    /// couldn't be read.
    ///
    /// A gap is stated **here**, deterministically, rather than left to the model to
    /// pass on: the chord suppresses the paste, so a run whose only source failed
    /// would otherwise say "Nothing to report" in the same words as a genuinely quiet
    /// day. The wording is the deterministic day summary's own tail, so the two
    /// surfaces report a gap identically.
    /// Pure, so the gap rule is testable without a provider that can fail on demand.
    static func detailLine(effects: [CommandToolRouter.Effect],
                           served: [String],
                           unreadable: [String]) -> String {
        let line = destination(effects: effects, served: served)
        guard !unreadable.isEmpty else { return line }
        return line + "  ·  couldn't read \(unreadable.joined(separator: ", "))"
    }

    /// Where it went, or who answered. Local writes name the app's own surface;
    /// anything a connector served names the connections, the same provenance rule the
    /// day-summary band follows.
    ///
    /// A connector write names **the connection it wrote to**, not Notes & Reminders:
    /// captioning a sent message "Saved to Notes & Reminders" is a plain lie about
    /// where the words went, and the one thing a receipt has to get right is the
    /// destination.
    private static func destination(effects: [CommandToolRouter.Effect],
                                    served: [String]) -> String {
        for effect in effects {
            switch effect {
            case .local(.noteCreated), .local(.reminderCreated):
                return "Saved to Notes & Reminders"
            case .connectorWrite(let tool, let written) where !written.isEmpty:
                return writeDestination(tool: tool, written: written)
            case .local(.read), .connectorWrite:
                continue
            }
        }
        let labels = Set(served).sorted()
        if !labels.isEmpty { return "From \(labels.joined(separator: ", "))" }
        return "On-device assistant"
    }

    private func icon(for router: CommandToolRouter) -> String {
        for effect in router.effects {
            switch effect {
            case .local(.reminderCreated): return "bell.badge.fill"
            case .local(.noteCreated): return "note.text"
            case .local(.read): continue
            case .connectorWrite(let tool, _): return Self.writeIcon(tool: tool)
            }
        }
        return "sparkles"
    }

    /// A write's destination line and symbol are read off the **capability** the tool
    /// touched rather than its name, so a write tool added later reads sensibly
    /// without a second switch to remember.
    private static func writeDestination(tool: String, written: [String]) -> String {
        let destination = written.joined(separator: ", ")
        switch ToolCatalog.descriptor(named: tool)?.capability {
        case .events: return "Added to \(destination)"
        default: return "Sent to \(destination)"
        }
    }

    private static func writeIcon(tool: String) -> String {
        switch ToolCatalog.descriptor(named: tool)?.capability {
        case .events: return "calendar.badge.plus"
        case .messages: return "paperplane.fill"
        default: return "checkmark.circle.fill"
        }
    }
}
