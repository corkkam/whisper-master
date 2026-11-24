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
    /// What the user had selected when they held the chord. Set, it adds
    /// `read_selection` to the tools and one line of context to the prompt.
    var selection: SelectionContext?
    /// The last answered command, when it is recent (`FollowUpWindow`). Set, the loop
    /// sends it as an earlier turn of the conversation (`AgentLoop.earlier`) and, when
    /// that run was tainted, this one is tainted from the start.
    var followUp: FollowUpWindow.Digest?
    /// The app in front when the chord went down. Set, the run offers the draft
    /// tools, which may only ever type into this app.
    var frontApp: SelectionReader.FrontApp?
    /// What the device tools touch. Injected so a test opens and reads nothing real.
    var device: DeviceToolRunner.Environment = .live

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
        /// The loop ran out of time or steps. Its last generation may still hold the
        /// model (`AgentLoop.generateWithinBudget` walks away from it, it can't stop
        /// it), so a caller about to generate again should not wait behind it.
        var budgetSpent = false
        /// The answer as the trace and the answer log may keep it: a placeholder when
        /// it repeats the selection the run read. The band still shows `result.answer`.
        let storableAnswer: String
        /// Untrusted text entered the run (`Taint`). Carried into a follow-up, never
        /// stored.
        var tainted = false
        /// Which brain ran it.
        var tier: AgentTier = .onDevice
        /// Text the model wrote for the front app, for the band. Never stored.
        var draft: AgentDraft?
    }

    /// - Parameter onStep: called as the loop moves, so the band can name the
    ///   connector it's waiting on. The caller owns the `AppState` write, per the
    ///   "view model is the only writer" rule.
    func perform(_ spoken: String,
                 generate: @escaping AgentLoop.Generate,
                 onStep: @escaping (AgentActivity) -> Void = { _ in }) async -> CommandAgentResult? {
        await run(spoken, generate: generate, onStep: onStep).result
    }

    /// - Parameters:
    ///   - generateNative: set, the loop runs the native tool-calling path on this
    ///     generator instead of `generate` (`CloudToolGenerator` for the endpoint tier).
    ///   - tier: which brain this is, for the answer line and the trace. Every rule
    ///     below — the taint, the card, the execution rule — is the same for both.
    func run(_ spoken: String,
             generate: @escaping AgentLoop.Generate,
             generateNative: AgentLoop.GenerateNative? = nil,
             tier: AgentTier = .onDevice,
             onStep: @escaping (AgentActivity) -> Void = { _ in }) async -> Run {
        let connectorTools = connectorsAllowed
            ? ToolRegistry.available(store: store, includeWrites: true)
            : []
        // Local first in the list: it's the fallback the prompt names, and a small
        // model biases toward what it read first.
        let tools = ToolPackRouter.pack(
            LocalToolCatalog.all
                + (selection == nil ? [] : [LocalToolCatalog.readSelection])
                + DeviceToolCatalog.offered(selection: selection != nil, frontApp: frontApp != nil)
                + connectorTools,
            spoken: spoken)

        // One flag for the whole run: a connector read and a selection read both gate
        // a later write, whichever runner served them. A follow-up starts with the
        // flag of the run it follows, whose answer is in its prompt. Its source is not
        // kept, so it counts as outside the selection: the conservative reading.
        let taint = Taint()
        taint.isSet = followUp?.tainted ?? false
        taint.outsideSelection = taint.isSet
        let connectorRouter = connectorTools.isEmpty
            ? nil
            : ToolRouter(store: store,
                         requestApproval: { [approvals] approval in await approvals.request(approval) },
                         taint: taint,
                         spoken: spoken)
        let router = CommandToolRouter(
            local: LocalToolRunner(
                notes: notes, alertStyle: alertStyle, soundName: soundName, now: now,
                // The capture's own words and audio, so a note the agent files keeps
                // what was actually said next to the model's rewrite of it.
                voice: .init(transcript: spoken, takeAudio: takeNoteAudio),
                selection: selection,
                taint: taint,
                requestApproval: { [approvals] approval in await approvals.request(approval) }),
            connectors: connectorRouter,
            device: DeviceToolRunner(
                store: store,
                requestApproval: { [approvals] approval in await approvals.request(approval) },
                environment: device,
                taint: taint,
                frontApp: frontApp,
                selection: selection,
                now: now),
            now: now)

        var loop = AgentLoop(tools: tools, router: router, generate: generate)
        loop.generateNative = generateNative
        // `thinks` describes the on-device model; an endpoint gets the plain budget.
        loop.budget = tier == .onDevice
            ? AgentLoop.budget(thinks: CleanupModel.General.thinks)
            : AgentLoop.defaultBudget
        // The prompt names the selection; the text itself comes only through the tool.
        loop.prompt = { [selection] toolList in
            let prompt = AgentPrompt.command(toolList: toolList)
            return selection.map { prompt + "\n\n" + $0.promptLine } ?? prompt
        }
        loop.nativePrompt = { [selection] in
            let prompt = AgentPrompt.commandNative()
            return selection.map { prompt + "\n\n" + $0.promptLine } ?? prompt
        }
        loop.earlier = followUp.map { ($0.question, $0.answer) }
        loop.now = now
        loop.onStep = onStep
        // The chord suppresses the paste, so an answer with nothing executed behind it
        // is a lost command — the loop corrects the model once before accepting one.
        loop.requiresToolBeforeAnswer = true
        let outcome = await loop.run(question: spoken)

        /// Every exit reports through this, so a decline can't leave the trace empty —
        /// the same shape `SessionAccounting` uses to make an unaccounted exit
        /// impossible.
        func run(_ result: CommandAgentResult?, _ declineReason: String = "") -> Run {
            let answer = result?.answer ?? ""
            var storable = router.selectionRead?.storable(answer) ?? answer
            // A model that repeats its draft in the answer must not store it there.
            if let draft = router.draft {
                storable = DeviceToolCatalog.strip(draft.text, from: storable)
            }
            return Run(result: result,
                       toolsOffered: tools.map(\.name),
                       connectorsAllowed: connectorsAllowed,
                       calls: router.journal,
                       turns: Self.traceTurns(outcome.turns, selection: router.selectionRead,
                                              draft: router.draft),
                       declineReason: result == nil ? declineReason : "",
                       budgetSpent: outcome.exhausted,
                       storableAnswer: storable,
                       tainted: taint.isSet,
                       tier: tier,
                       draft: router.draft)
        }

        // Escape stopped the loop. Something a tool already created stands, and is
        // reported below like any run that ran dry after acting.
        if Task.isCancelled, outcome.exhausted, !router.didCreateSomething {
            return run(nil, "Stopped with Escape before anything was created, so the "
                + "words were filed instead.")
        }
        guard !router.executed.isEmpty else {
            if tools.isEmpty {
                return run(nil, "No tools were available, so there was nothing the assistant could do.")
            }
            return run(nil, (router.journal.isEmpty
                ? "The model answered without calling a tool"
                : "Every tool call failed or was refused")
                + ", so nothing was acted on and the words were filed instead.")
        }
        // Reading the selection is not acting. The prompt invites that call on every
        // chord press, so "remind me to email Dana" with text selected can end as
        // read_selection plus prose — and the paste is suppressed, so the words would
        // be lost. A capture that opens with a note or reminder trigger is therefore
        // filed unless something else ran. (Legal here: this is behind the chord.)
        if router.executed.allSatisfy({ $0 == LocalToolCatalog.readSelection.name }),
           CommandDetector.detect(spoken) != nil {
            return run(nil, "The model only read the selection, so nothing was acted on "
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
                                    unreadable: router.unreadable,
                                    tier: tier),
            icon: icon(for: router),
            createdSomething: router.didCreateSomething))
    }

    /// The loop's transcript, ready to store: the model's own turns and the loop's
    /// replies to them, clamped.
    ///
    /// Tool turns are dropped — their text is already journalled in `calls`, and a
    /// trace that keeps every result twice is what `TraceText.clamp` exists to stop.
    /// After a `read_selection`, a turn that repeats the selection is kept as a
    /// placeholder, because traces persist.
    private static func traceTurns(_ turns: [AgentTurn],
                                   selection: SelectionContext?,
                                   draft: AgentDraft?) -> [TraceTurn] {
        turns
            .filter { $0.role != .tool }
            .map { turn in
                // A model turn that calls a draft tool keeps the call, not the text,
                // and any later turn that repeats the staged draft keeps its length.
                var shown = turn.role == .model ? DeviceToolCatalog.storableTurn(turn.text) : turn.text
                if let draft { shown = DeviceToolCatalog.strip(draft.text, from: shown) }
                let text = selection?.storable(shown) ?? shown
                return TraceTurn(role: turn.role.rawValue, text: TraceText.clamp(text))
            }
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
    /// A remote run says so on this line too, never "On-device assistant".
    static func detailLine(effects: [CommandToolRouter.Effect],
                           served: [String],
                           unreadable: [String],
                           tier: AgentTier = .onDevice) -> String {
        var line = destination(effects: effects, served: served)
        if let label = tier.answerLabel {
            line = line == onDeviceLine
                ? "Answered by \(label)"
                : line + "  \u{00B7}  via \(label)"
        }
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
            case .device(.openedApp): return "On \(DeviceToolCatalog.thisMacLabel)"
            case .device(.openedURL): return "In your browser"
            case .device(.draftStaged(let draft)): return "Draft for \(draft.app.name)"
            case .local(.read), .connectorWrite:
                continue
            }
        }
        let labels = Set(served).sorted()
        if !labels.isEmpty { return "From \(labels.joined(separator: ", "))" }
        return onDeviceLine
    }

    private static let onDeviceLine = "On-device assistant"

    private func icon(for router: CommandToolRouter) -> String {
        for effect in router.effects {
            switch effect {
            case .local(.reminderCreated): return "bell.badge.fill"
            case .local(.noteCreated): return "note.text"
            case .local(.read): continue
            case .connectorWrite(let tool, _): return Self.writeIcon(tool: tool)
            case .device(.openedApp): return "macwindow"
            case .device(.openedURL): return "safari"
            case .device(.draftStaged): return "text.cursor"
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
