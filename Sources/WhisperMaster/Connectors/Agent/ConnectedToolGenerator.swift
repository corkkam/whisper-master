import Foundation

/// `AgentLoop.GenerateNative` over the user's own command-line tool (`ConnectedTool`):
/// one run of the tool per loop turn, as a **text generator only**.
///
/// The tool runs with no tools of its own, so this writes the function list and the
/// call format into the prompt, in the Qwen3 `<tool_call>` shape `NativeToolCallParser`
/// reads. The loop, the taint rule, the approval cards and "only an executed tool
/// counts" stay in this app, exactly as for the endpoint.
///
/// Before every turn it checks, and refuses the turn when one fails:
/// - **The live state** (`mayContinue`): a Pause, a Revoke or a sign-out in the middle
///   of a run stops the next turn.
/// - **The file** at `executable` is still the one the Test passed on.
///
/// During every run, **the start-up record of that same run** (`ConnectedTool.StreamCheck`):
/// a tool, an MCP server, a hook, an unknown event or another version stops the run at
/// that line, discards everything, and clears the Test (`onUntrusted`), so the user's
/// hooks never get the chord's text quietly.
///
/// The prompt goes on stdin; argv holds constants only. The send is recorded before
/// the launch, as the endpoint does: counts only. **Every failure is nil**, the
/// endpoint's rule, and the view model hands the words to the on-device tier.
struct ConnectedToolGenerator: Sendable {
    let kind: ConnectedTool.Kind
    let executable: URL
    /// The version every start-up record must show, and the file that must still run.
    let tested: ConnectedTool.Tested
    let sent: EndpointSendLog
    /// Shorter than the loop's 30 s budget. About 4 s a turn on the probe.
    var timeout: TimeInterval = 20
    /// An answer is a sentence; the room is for a tool that prints one JSON line per event.
    var outputCap = 1 << 20
    var runner: CLIProcess.Runner = CLIProcess.live
    var environment = ConnectedTool.environment()
    /// Asked before every turn: still on, not paused, still allowed for this tool.
    var mayContinue: @Sendable () async -> Bool = { true }
    /// The run showed the tool is not what its Test passed on. The view model clears the
    /// Test, so nothing more is sent until it passes again.
    var onUntrusted: @Sendable () async -> Void = {}
    /// The tool's name and a fixed phrase only. Never the prompt, never its output.
    var log: @Sendable (String) -> Void = { Log.connectors.notice("\($0, privacy: .public)") }

    init(kind: ConnectedTool.Kind, executable: URL, tested: ConnectedTool.Tested, sent: EndpointSendLog) {
        self.kind = kind
        self.executable = executable
        self.tested = tested
        self.sent = sent
    }

    var generate: AgentLoop.GenerateNative {
        { messages, tools in await reply(messages, tools: tools) }
    }

    func reply(_ messages: [[String: String]], tools: [String]) async -> String? {
        guard await mayContinue() else { return fail("was paused or turned off during the run") }
        guard let installed = ConnectedTool.binary(at: executable), installed == tested.binary else {
            return await distrust("changed since its Test passed")
        }
        let check = kind == .claudeCode ? ConnectedTool.StreamCheck(expecting: tested.version) : nil
        var lineCheck: CLIProcess.LineCheck?
        if let check { lineCheck = { check.accept($0) } }

        sent.record(Self.framed(messages), tools: tools)
        let outcome = await runner(
            CLIProcess.Command(executable: executable, arguments: ConnectedTool.arguments(kind),
                               environment: environment),
            Data(Self.prompt(messages, tools: tools, kind: kind).utf8), timeout, outputCap, lineCheck)

        if outcome == .refused {
            return await distrust(check?.problem ?? "printed something the app does not allow")
        }
        guard case .exited(0, let stdout) = outcome else {
            return fail(ConnectedTool.failure(outcome, kind: kind, timeout: timeout))
        }
        if let check, check.version == nil { return await distrust("printed no start-up record") }
        guard let raw = ConnectedTool.reply(from: stdout, kind: kind) else {
            return fail(ConnectedTool.failure(outcome, kind: kind, timeout: timeout))
        }
        guard let reply = Self.normalized(raw) else { return fail("wrote a function call the app could not read") }
        return reply
    }

    /// nil `reason` is a cancel: Escape or the loop's budget, which the loop reports.
    private func fail(_ reason: String?) -> String? {
        guard let reason else { return nil }
        sent.recordFailure(reason)
        log("Connected tool \(kind.name) \(reason).")
        return nil
    }

    private func distrust(_ reason: String) async -> String? {
        _ = fail(reason)
        await onUntrusted()
        return nil
    }

    // MARK: - The reply

    /// The reply as the loop should read it, or nil when it is shaped like a call that
    /// cannot be read (it must never be spoken as an answer).
    ///
    /// - Two calls: only the first complete `<tool_call>` block, because the loop runs
    ///   one call per turn and the stored turn must show only the call that ran.
    /// - A call without its tags, bare or in a code fence: `{"name": …, "arguments": …}`
    ///   becomes a tagged call. Here only: the endpoint's parser keeps its meaning.
    /// - The `{"tool": …}` and `{"answer": …}` shapes pass through: the shared parser
    ///   reads them.
    static func normalized(_ reply: String) -> String? {
        if let open = reply.range(of: "<tool_call>"),
           let close = reply.range(of: "</tool_call>", range: open.upperBound..<reply.endIndex) {
            return String(reply[open.lowerBound..<close.upperBound])
        }
        var body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```"), body.hasSuffix("```"), body.count >= 6 {
            body = String(body.dropFirst(3).dropLast(3).drop { $0 != "\n" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard body.hasPrefix("{") else { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        else { return nil }
        if object["tool"] != nil || object["answer"] != nil { return reply }
        guard let name = object["name"] as? String, !name.isEmpty,
              Set(object.keys).isSubset(of: ["name", "arguments"]),
              object["arguments"] == nil || object["arguments"] is [String: Any]
        else { return nil }
        return "<tool_call>\(body)</tool_call>"
    }

    // MARK: - The prompt

    /// The fixed part this generator adds: how to call a function.
    static let howToCall = """
        # How to call a function
        The functions are JSON schemas, one per line, between <tools> and </tools>.
        To call one, reply with only this:
        <tool_call>{"name": "<function name>", "arguments": {<arguments as JSON>}}</tool_call>
        Call one function per reply. To report the result, reply in plain words with no <tool_call>.
        You have no other tools. Do not run commands. Do not read files.
        Reply with the assistant's next turn only.
        """

    /// What goes on stdin: the loop's instructions, the call format, the functions, and
    /// the conversation (the roles of `AgentLoop.wireMessages`). Claude gets
    /// `textOnlySystemPrompt` in argv; Codex has no such flag, so it leads here.
    ///
    /// **Each turn is one JSON object on one line**, its content a JSON string. A mail or
    /// a selection that holds "[user]" or a line break followed by a fake role stays
    /// inside its own string, so text the assistant read can never pose as a turn.
    static func prompt(_ messages: [[String: String]], tools: [String], kind: ConnectedTool.Kind) -> String {
        var rest = messages[...]
        var instructions = ""
        if rest.first?["role"] == "system" {
            instructions = rest.first?["content"] ?? ""
            rest = rest.dropFirst()
        }
        let conversation = rest.map { turn($0["role"], $0["content"] ?? "") }
        return ((kind == .codex ? [ConnectedTool.textOnlySystemPrompt] : [])
            + [instructions, howToCall,
               (["<tools>"] + tools + ["</tools>"]).joined(separator: "\n"),
               (["# Conversation, one JSON object per line, oldest first"] + conversation)
                .joined(separator: "\n")])
            .joined(separator: "\n\n")
    }

    private static func turn(_ role: String?, _ content: String) -> String {
        let label: String
        switch role {
        case "user": label = "user"
        case "assistant": label = "assistant"
        case "tool": label = "function result"
        // A note from the loop in the middle of a run.
        default: label = "app note"
        }
        return #"{"role": "\#(label)", "content": \#(jsonString(content))}"#
    }

    /// `content` as a JSON string literal: quotes, backslashes and every line break escaped.
    private static func jsonString(_ content: String) -> String {
        (try? JSONSerialization.data(withJSONObject: content, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// The messages as the send log counts them: the text-only prompt and the call
    /// format join the first system message, so they count as instructions and "what
    /// was sent" covers argv too.
    static func framed(_ messages: [[String: String]]) -> [[String: String]] {
        let fixed = ConnectedTool.textOnlySystemPrompt + "\n\n" + howToCall
        var framed = messages
        if framed.first?["role"] == "system" {
            framed[0]["content"] = fixed + "\n\n" + (framed[0]["content"] ?? "")
        } else {
            framed.insert(["role": "system", "content": fixed], at: 0)
        }
        return framed
    }
}
