import Foundation

#if DEBUG
/// Dev-only head-to-head bench: does the model's **native** tool-calling emit a
/// parseable tool call more reliably than the hand-rolled JSON prompt, on the real
/// qwen? Triggered by `WM_AGENT_TOOL_EVAL` (see AppMain), it loads the model once and
/// runs a fixed set of representative spoken commands through **three** first-turn
/// generation paths against the same tool set, then prints a comparison.
///
/// Not a `swift test` — MLX inference cannot run there. Same env-hook posture as
/// `SnapshotMode` / `EvalRunner`, and compiled out of Release.
///
/// It measures the **first** model turn only, deliberately: whether the model, shown
/// the tools, emits a well-formed call to the right tool with sane arguments. That is
/// the hypothesis. Running the whole loop would fold in retry and repeat-detection
/// behaviour that is identical for both paths and would only add noise.
@MainActor
enum AgentToolEval {
    /// A tiny thread-safe flag so AppMain can pump the run loop until the async run
    /// completes (see the hook there).
    final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// One spoken command and the tool a correct run should call.
    private struct Case {
        let spoken: String
        let expectedTool: String
    }

    private static let cases: [Case] = [
        .init(spoken: "what's on my calendar tomorrow", expectedTool: "list_calendar_events"),
        .init(spoken: "send a slack to the ops channel saying I'll be late", expectedTool: "send_message"),
        .init(spoken: "remind me to call mom at 6", expectedTool: "create_reminder"),
        .init(spoken: "add a dentist appointment to my personal calendar friday at 3", expectedTool: "create_calendar_event"),
        .init(spoken: "what are my unread emails", expectedTool: "list_mail"),
        .init(spoken: "what tasks are assigned to me", expectedTool: "list_tasks"),
        .init(spoken: "show me my recent messages", expectedTool: "list_messages"),
        .init(spoken: "make a note that the wifi password is basalt harbor nineteen", expectedTool: "create_note"),
        .init(spoken: "what files are in my drive", expectedTool: "list_files"),
        .init(spoken: "what accounts do i have connected", expectedTool: "list_connectors"),
        .init(spoken: "post to the eng channel that the build is green", expectedTool: "send_message"),
        .init(spoken: "remind me to submit the report tomorrow morning", expectedTool: "create_reminder"),
        // Messier, dictation-shaped: run-ons, a self-correction, an implicit time, and
        // a bare thought with nothing to act on. These are where the two prompt shapes
        // are more likely to separate than on the clean commands above.
        .init(spoken: "uh can you check what meetings I've got going on later today", expectedTool: "list_calendar_events"),
        .init(spoken: "message the design channel no wait the ops channel and tell them the deploy is done", expectedTool: "send_message"),
        .init(spoken: "book thirty minutes with the personal calendar for a review tomorrow at four", expectedTool: "create_calendar_event"),
        .init(spoken: "just jot down that I should follow up with the vendor about pricing", expectedTool: "create_note"),
    ]

    /// One path's verdict on one case.
    private struct Verdict {
        let parsedCall: Bool     // emitted a tool call the parser accepted
        let tool: String?        // which tool, if a call
        let arguments: [String: String]
        let rawExcerpt: String
    }

    static func run() async {
        print("=== Agent tool-calling bench (real Qwen3-4B-Instruct-2507) ===")

        // **The general model, not the cleanup slot.** This bench measures tool
        // calling, and the cleanup slot holds S1-mini — a text normalizer that
        // cannot emit a tool call. Pointed there it returns prose, nothing parses,
        // and the bench reports every path as failing to call a tool while its own
        // banner claims it is running the 4B. Same mistake as `AgentLoop`, which is
        // why both now go through `.general`.
        await MlxCleanupService.prepareGeneralIfInstalled()
        guard await MlxCleanupService.general.isReady else {
            print("ABORT: assistant model not installed at \(CleanupModel.General.directory.path)")
            print("Settings -> Assistant -> Download now, or use the chord once.")
            return
        }
        print("Model loaded from \(CleanupModel.General.directory.lastPathComponent)\n")

        let tools = buildTools()
        print("Tools offered (\(tools.count)): \(tools.map(\.name).joined(separator: ", "))\n")

        let toolList = ToolRegistry.promptDescription(for: tools)
        let handSystem = AgentPrompt.command(toolList: toolList)
        let nativeSystem = AgentPrompt.commandNative()
        let schemas = ToolSchema.functionSchemas(for: tools)

        var wrappedParse = 0, wrappedCorrect = 0
        var handParse = 0, handCorrect = 0
        var nativeParse = 0, nativeCorrect = 0

        for testCase in cases {
            let wrapped = await cleanupWrapped(testCase.spoken, system: handSystem, tools: tools)
            let hand = await handRolled(testCase.spoken, system: handSystem, tools: tools)
            let native = await nativePath(testCase.spoken, system: nativeSystem,
                                          schemas: schemas, tools: tools)
            if wrapped.parsedCall { wrappedParse += 1 }
            if wrapped.tool == testCase.expectedTool { wrappedCorrect += 1 }
            if hand.parsedCall { handParse += 1 }
            if hand.tool == testCase.expectedTool { handCorrect += 1 }
            if native.parsedCall { nativeParse += 1 }
            if native.tool == testCase.expectedTool { nativeCorrect += 1 }

            print("• \"\(testCase.spoken)\"  (expected: \(testCase.expectedTool))")
            printVerdict("  via clean  ", wrapped, expected: testCase.expectedTool)
            printVerdict("  hand-rolled", hand, expected: testCase.expectedTool)
            printVerdict("  native     ", native, expected: testCase.expectedTool)
            print("")
        }

        let n = cases.count
        print("=== Summary over \(n) cases ===")
        print(String(format: "via clean   : parseable tool call %d/%d   correct tool %d/%d",
                     wrappedParse, n, wrappedCorrect, n))
        print(String(format: "hand-rolled : parseable tool call %d/%d   correct tool %d/%d",
                     handParse, n, handCorrect, n))
        print(String(format: "native      : parseable tool call %d/%d   correct tool %d/%d",
                     nativeParse, n, nativeCorrect, n))
        let delta = nativeCorrect - handCorrect
        print("correct-tool delta (native − hand): \(delta >= 0 ? "+" : "")\(delta)")
        let cost = handCorrect - wrappedCorrect
        print("cost of routing the agent through clean: \(cost >= 0 ? "−" : "+")\(abs(cost))")
        print("")

        await runSecondTurn(tools: tools, handSystem: handSystem,
                            nativeSystem: nativeSystem, schemas: schemas)
    }

    // MARK: - The three paths, first turn only

    /// **The control**: the agent turn sent through `clean`, the transcript-cleanup
    /// entry point, exactly as the loop used to send it. Kept as an arm of the bench
    /// rather than deleted because it is the measurement that says what the cleanup
    /// wrapper costs — its control line, its word-count token budget and its chunker
    /// are all aimed at a dictation, not at a tool call. If a future change points the
    /// loop back at `clean`, this arm is what shows the damage.
    private static func cleanupWrapped(_ spoken: String, system: String,
                                       tools: [ToolDescriptor]) async -> Verdict {
        let user = AgentLoop.render([.init(role: .user, text: spoken)])
        let raw = await MlxCleanupService.general.clean(user, systemPrompt: system) ?? ""
        return verdict(from: ToolCallParser.parse(raw, tools: tools), raw: raw)
    }

    /// The production path: the agent generator fed the same `"Question: …"` render
    /// `AgentLoop` uses, parsed by `ToolCallParser`.
    private static func handRolled(_ spoken: String, system: String,
                                   tools: [ToolDescriptor]) async -> Verdict {
        let user = AgentLoop.render([.init(role: .user, text: spoken)])
        let raw = await MlxCleanupService.general.generateAgent(user, systemPrompt: system) ?? ""
        return verdict(from: ToolCallParser.parse(raw, tools: tools), raw: raw)
    }

    /// The candidate path: structured messages + tool schemas through the native chat
    /// template, parsed by `NativeToolCallParser`.
    private static func nativePath(_ spoken: String, system: String,
                                   schemas: [String], tools: [ToolDescriptor]) async -> Verdict {
        let messages = AgentLoop.wireMessages(system: system, [.init(role: .user, text: spoken)])
        let raw = await MlxCleanupService.general.generateWithTools(
            messages: messages, toolSchemasJSON: schemas) ?? ""
        return verdict(from: NativeToolCallParser.parse(raw, tools: tools), raw: raw)
    }

    private static func verdict(from parsed: Result<AgentStep, ToolCallParseError>,
                                raw: String) -> Verdict {
        let excerpt = raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .prefix(160)
        switch parsed {
        case .success(.call(let call)):
            return Verdict(parsedCall: true, tool: call.tool,
                           arguments: call.arguments, rawExcerpt: String(excerpt))
        case .success(.answer), .failure:
            return Verdict(parsedCall: false, tool: nil,
                           arguments: [:], rawExcerpt: String(excerpt))
        }
    }

    private static func printVerdict(_ label: String, _ v: Verdict, expected: String) {
        // `correctTool` is decided here against the case, keeping `Verdict` about the
        // parse alone.
        let correct = v.tool == expected
        let mark = !v.parsedCall ? "no call " : (correct ? "OK      " : "wrong   ")
        let tool = v.tool ?? "—"
        let args = v.arguments.isEmpty
            ? ""
            : "  args: " + v.arguments.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        print("\(label): [\(mark)] \(tool)\(args)")
        if !v.parsedCall { print("\(label)            raw: \(v.rawExcerpt)") }
    }

    // MARK: - The turn after a tool result

    /// The first turn is the easy one, and the summary above says all three paths win
    /// it. **The turn that reads a tool result is the one that separates them**, and it
    /// is the turn a real command spends most of its budget on.
    ///
    /// A day's calendar merged across two connections runs to a few hundred words, and
    /// `clean` — the cleanup entry point the loop used to generate through — splits
    /// anything past `TranscriptChunker.maxWords` into pieces, generates each one
    /// separately and joins them with a space. What comes back is not one reply to the
    /// conversation; it is several, concatenated. This measures that rather than
    /// asserting it.
    private static func runSecondTurn(tools: [ToolDescriptor], handSystem: String,
                                      nativeSystem: String, schemas: [String]) async {
        print("=== The turn after a tool result (a \(wordCount(bigToolResult))-word listing) ===")
        print("chunk budget: \(TranscriptChunker.maxWords) words — "
            + "\(TranscriptChunker.needsChunking(bigToolResult) ? "over it" : "under it")\n")

        // **Each path gets its own finish nudge, because production does.** Handing the
        // native path a nudge that names `{"answer":"…"}` is how the envelope ends up
        // in a plain-text reply — measured here before `AgentLoop` was taught to word
        // the nudge per path, and the reason it now does.
        func conversation(nudge: String) -> [AgentLoop.AgentMessage] {
            [
                .init(role: .user, text: "what's on my calendar today"),
                .init(role: .assistant, text: #"{"tool":"list_calendar_events","args":{}}"#),
                .init(role: .tool, text: bigToolResult, tool: "list_calendar_events"),
                .init(role: .system, text: nudge),
            ]
        }
        let rendered = AgentLoop.render(conversation(
            nudge: "Answer now with {\"answer\":\"...\"} if that is enough, "
                + "otherwise call another tool."))
        let wire = AgentLoop.wireMessages(system: nativeSystem, conversation(
            nudge: "Answer now in plain words if that is enough, otherwise call "
                + "another function."))

        let viaClean = await MlxCleanupService.general.clean(
            rendered, systemPrompt: handSystem) ?? ""
        let viaAgent = await MlxCleanupService.general.generateAgent(
            rendered, systemPrompt: handSystem) ?? ""
        let viaNative = await MlxCleanupService.general.generateWithTools(
            messages: wire, toolSchemasJSON: schemas) ?? ""

        report("via clean  ", viaClean, parse: { ToolCallParser.parse($0, tools: tools) })
        report("hand-rolled", viaAgent, parse: { ToolCallParser.parse($0, tools: tools) })
        report("native     ", viaNative, parse: { NativeToolCallParser.parse($0, tools: tools) })
    }

    /// Whether the reply is one usable answer, and what it looks like. An answer that
    /// names an event from the fixture is grounded in the result it was given; one that
    /// doesn't is either invented or a fragment of something else.
    private static func report(_ label: String, _ raw: String,
                               parse: (String) -> Result<AgentStep, ToolCallParseError>) {
        let answer: String?
        switch parse(raw) {
        case .success(.answer(let text)): answer = text
        case .success(.call(let call)): answer = nil; print("\(label): [another call] \(call.tool)")
        case .failure(let error): answer = nil; print("\(label): [unusable] \(error)")
        }
        guard let answer else {
            print("\(label)              raw (\(wordCount(raw)) words): "
                + raw.replacingOccurrences(of: "\n", with: " ").prefix(220))
            return
        }
        let grounded = groundingTerms.contains { answer.localizedCaseInsensitiveContains($0) }
        print("\(label): [answer, \(grounded ? "grounded" : "UNGROUNDED")] "
            + answer.replacingOccurrences(of: "\n", with: " ").prefix(220))
    }

    /// Names that appear only in `bigToolResult`, so an answer carrying one was written
    /// from the result rather than from the question.
    private static let groundingTerms = ["Basalt", "Harbor", "Pemberton", "Q3 pricing"]

    /// A day merged across two calendars, at the size the router actually returns
    /// (15 items per connection). Deliberately past the 240-word chunk budget.
    private static let bigToolResult: String = {
        let work = (1...9).map { index in
            "• 0\(index):00 — Work: standup with the platform pod, room Basalt \(index). "
                + "Attendees: Sam Pemberton, Alex Ruiz, Dana Okafor. Notes: carry over the "
                + "migration item from yesterday and confirm the Q3 pricing sheet is signed off."
        }
        let personal = (1...6).map { index in
            "• 1\(index):00 — Personal: Harbor clinic follow-up \(index), 30 minutes, "
                + "with a reminder to bring the referral letter and the parking permit."
        }
        return (["Work calendar:"] + work + ["Personal calendar:"] + personal)
            .joined(separator: "\n")
    }()

    private static func wordCount(_ text: String) -> Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }

    // MARK: - Tools

    /// The tool set a real spoken command sees: the on-device local tools plus a
    /// representative spread of connectors, expanded exactly as `CommandAgentService`
    /// does it. Persistence off so seeding never touches a real account file.
    private static func buildTools() -> [ToolDescriptor] {
        let store = ConnectorInstanceStore()
        store.persistenceEnabled = false
        store.add(ConnectorInstance(
            kind: .googleCalendar, label: "Work", identity: "sam@acme.com",
            config: .calendars(identifiers: ["mock-work"], sourceTitle: "Google")))
        store.add(ConnectorInstance(
            kind: .googleCalendar, label: "Personal", identity: "sam@gmail.com",
            config: .calendars(identifiers: ["mock-personal"], sourceTitle: "Google")))
        store.add(ConnectorInstance(kind: .slack, label: "Work chat", identity: "Acme"))
        store.add(ConnectorInstance(kind: .gmail, label: "Gmail", identity: "sam@gmail.com"))
        store.add(ConnectorInstance(kind: .googleDrive, label: "Drive", identity: "sam@gmail.com"))
        store.add(ConnectorInstance(kind: .linear, label: "Linear", identity: "Acme"))
        return LocalToolCatalog.all + ToolRegistry.available(store: store, includeWrites: true)
    }
}
#endif
