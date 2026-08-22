import Foundation

#if DEBUG
/// Dev-only head-to-head bench: does the model's **native** tool-calling emit a
/// parseable tool call more reliably than the hand-rolled JSON prompt, on the real
/// qwen? Triggered by `WM_AGENT_TOOL_EVAL` (see AppMain), it loads the model once and
/// runs a fixed set of representative spoken commands through **both** first-turn
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

    /// The same 16 commands the in-app Model Lab runs, from the one list both
    /// read (`LabSuiteLoader.toolCases`). Two benches drifting apart on which
    /// commands they ask about would make their numbers incomparable, which is
    /// the only reason to have two.
    private static let cases: [Case] = LabSuiteLoader.toolCases.map {
        Case(spoken: $0.spoken, expectedTool: $0.expectedTool)
    }

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

        var handParse = 0, handCorrect = 0
        var nativeParse = 0, nativeCorrect = 0

        for testCase in cases {
            let hand = await handRolled(testCase.spoken, system: handSystem, tools: tools)
            let native = await nativePath(testCase.spoken, system: nativeSystem,
                                          schemas: schemas, tools: tools)
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
    }

    // MARK: - The two paths, first turn only

    /// The current production path: the KV-cached cleanup generator fed the same
    /// `"Question: …"` render `AgentLoop` uses, parsed by `ToolCallParser`.
    private static func handRolled(_ spoken: String, system: String,
                                   tools: [ToolDescriptor]) async -> Verdict {
        let user = AgentLoop.render([.init(role: .user, text: spoken)])
        let raw = await MlxCleanupService.general.clean(user, systemPrompt: system) ?? ""
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

    // MARK: - Tools

    /// The tool set a real spoken command sees. Shared with the lab's suite
    /// (`LabToolBench.buildTools`) so the two benches offer the same tools.
    private static func buildTools() -> [ToolDescriptor] { LabToolBench.buildTools() }
}
#endif
