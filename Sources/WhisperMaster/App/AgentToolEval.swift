import Foundation

/// The assistant suite: shown the tools, does the model call the right one?
///
/// Triggered by `WM_AGENT_TOOL_EVAL` (see AppMain). It loads the model once and runs
/// every case through **both** first-turn generation paths against the same tool set
/// — the hand-rolled JSON prompt that ships today, and the model's native
/// tool-calling — then prints a comparison and, when `WM_EVAL_OUT` is set, writes a
/// `results.json` in the same shape `EvalRunner` produces, so the scores land on
/// /eval beside the cleanup suite.
///
/// Cases come from `WM_EVAL_CASES` (`eval/text-cleanup/assistant-cases.jsonl`), with
/// the built-in list below as the fallback so the bench still runs with no arguments.
/// A case's `must_contain` is the tool name a correct run has to call, which is what
/// lets the existing keyword scorer grade this suite without knowing anything about
/// tools.
///
/// Not a `swift test`: MLX's Metal shaders only compile under xcodebuild, so this
/// runs from the built app. It is **not** compiled out of Release, for the same
/// reason `EvalRunner` is not — `Scripts/release.sh` grades the bundle it just built,
/// and a suite that only exists in Debug cannot grade a release. The hook is inert
/// unless the environment variable is set.
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
        let id: String
        let category: String
        let spoken: String
        let expectedTool: String

        /// `id` and `category` default so the built-in list below stays readable; a
        /// built-in case gets a stable id derived from its own words, which is enough
        /// for a bench run that is not being published.
        init(id: String? = nil, category: String = "uncategorized",
             spoken: String, expectedTool: String) {
            self.id = id ?? "asst-" + spoken.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.prefix(4).joined(separator: "-")
            self.category = category
            self.spoken = spoken
            self.expectedTool = expectedTool
        }
    }

    /// Cases from `WM_EVAL_CASES`, else the built-in list.
    ///
    /// The file is the same JSONL every other suite uses: `input` is the spoken
    /// command and the first `must_contain` entry is the tool that has to be called.
    /// A malformed line is skipped rather than aborting the run — twenty minutes of
    /// model time should not be thrown away by one bad comma.
    private static func loadCases() -> [Case] {
        guard let path = ProcessInfo.processInfo.environment["WM_EVAL_CASES"],
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return builtInCases }

        var loaded: [Case] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
                  let id = obj["id"] as? String,
                  let spoken = obj["input"] as? String ?? (obj["input"] as? [String: Any])?["text"] as? String,
                  let expected = (obj["must_contain"] as? [String])?.first
            else { continue }
            loaded.append(Case(id: id, category: obj["category"] as? String ?? "uncategorized",
                               spoken: spoken, expectedTool: expected))
        }
        return loaded.isEmpty ? builtInCases : loaded
    }

    private static let builtInCases: [Case] = [
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
        print("=== Assistant suite: tool calling on the real Qwen3-4B-Instruct-2507 ===")
        let cases = loadCases()

        await MlxCleanupService.shared.prepare(configuration: .init(directory: CleanupModel.directory))
        guard await MlxCleanupService.shared.isReady else {
            print("ABORT: cleanup model not ready (is it fully downloaded at \(CleanupModel.directory.path)?)")
            return
        }
        print("Model loaded from \(CleanupModel.directory.lastPathComponent)\n")

        let tools = buildTools()
        print("Tools offered (\(tools.count)): \(tools.map(\.name).joined(separator: ", "))\n")

        let toolList = ToolRegistry.promptDescription(for: tools)
        let handSystem = AgentPrompt.command(toolList: toolList)
        let nativeSystem = AgentPrompt.commandNative()
        let schemas = ToolSchema.functionSchemas(for: tools)

        var handParse = 0, handCorrect = 0
        var nativeParse = 0, nativeCorrect = 0
        var rows: [[String: Any]] = []

        for testCase in cases {
            let handStart = Date()
            let hand = await handRolled(testCase.spoken, system: handSystem, tools: tools)
            let handMs = Int(Date().timeIntervalSince(handStart) * 1000)
            let nativeStart = Date()
            let native = await nativePath(testCase.spoken, system: nativeSystem,
                                          schemas: schemas, tools: tools)
            let nativeMs = Int(Date().timeIntervalSince(nativeStart) * 1000)
            rows.append(row(testCase, hand, target: "assistant", ms: handMs))
            rows.append(row(testCase, native, target: "assistant-native", ms: nativeMs))
            if hand.parsedCall { handParse += 1 }
            if hand.tool == testCase.expectedTool { handCorrect += 1 }
            if native.parsedCall { nativeParse += 1 }
            if native.tool == testCase.expectedTool { nativeCorrect += 1 }

            print("• \"\(testCase.spoken)\"  (expected: \(testCase.expectedTool))")
            printVerdict("  hand-rolled", hand, expected: testCase.expectedTool)
            printVerdict("  native     ", native, expected: testCase.expectedTool)
            print("")
        }

        let n = cases.count
        print("=== Summary over \(n) cases ===")
        print(String(format: "hand-rolled : parseable tool call %d/%d   correct tool %d/%d",
                     handParse, n, handCorrect, n))
        print(String(format: "native      : parseable tool call %d/%d   correct tool %d/%d",
                     nativeParse, n, nativeCorrect, n))
        let delta = nativeCorrect - handCorrect
        print("correct-tool delta (native − hand): \(delta >= 0 ? "+" : "")\(delta)")

        if let outPath = ProcessInfo.processInfo.environment["WM_EVAL_OUT"] {
            writeJSON(rows, to: outPath)
            print("wrote \(rows.count) rows to \(outPath)")
        }
    }

    // MARK: - Results, in the shape the rest of the eval speaks

    /// One scored row, matching `EvalRunner`'s output exactly.
    ///
    /// `llm_output` is the tool name followed by its arguments rather than the raw
    /// generation, because the scorer grades on `must_contain` and the thing being
    /// graded is *which tool was called*. Putting the name in the output is what lets
    /// one keyword scorer serve both suites. The arguments ride along after it so the
    /// proof sheet shows what the model actually asked for; nothing matches on them
    /// yet.
    ///
    /// `deterministic` is the spoken command, so the page's diff puts the command on
    /// one line and the call it produced on the next.
    private static func row(_ testCase: Case, _ verdict: Verdict,
                            target: String, ms: Int) -> [String: Any] {
        let arguments = verdict.arguments.isEmpty
            ? ""
            : " " + verdict.arguments.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        let output = verdict.parsedCall
            ? "\(verdict.tool ?? "?")\(arguments)"
            : "no tool call: \(verdict.rawExcerpt)"
        return [
            "id": testCase.id,
            "category": testCase.category,
            "target": target,
            "input_kind": "text",
            "deterministic": testCase.spoken,
            "llm_output": output,
            // No faithfulness guard on this path: the guard exists to stop the
            // cleanup inventing words, and a tool call is not a transcript.
            "guard": ["accepted": true],
            "wer": NSNull(),
            "latency_ms": ["deterministic": 0, "llm": ms, "total": ms],
        ]
    }

    private static func writeJSON(_ obj: [[String: Any]], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        else { return }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - The two paths, first turn only

    /// The current production path: the KV-cached cleanup generator fed the same
    /// `"Question: …"` render `AgentLoop` uses, parsed by `ToolCallParser`.
    private static func handRolled(_ spoken: String, system: String,
                                   tools: [ToolDescriptor]) async -> Verdict {
        let user = AgentLoop.render([.init(role: .user, text: spoken)])
        let raw = await MlxCleanupService.shared.clean(user, systemPrompt: system) ?? ""
        return verdict(from: ToolCallParser.parse(raw, tools: tools), raw: raw)
    }

    /// The candidate path: structured messages + tool schemas through the native chat
    /// template, parsed by `NativeToolCallParser`.
    private static func nativePath(_ spoken: String, system: String,
                                   schemas: [String], tools: [ToolDescriptor]) async -> Verdict {
        let messages = AgentLoop.wireMessages(system: system, [.init(role: .user, text: spoken)])
        let raw = await MlxCleanupService.shared.generateWithTools(
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
