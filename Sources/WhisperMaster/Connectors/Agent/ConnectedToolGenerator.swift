import Foundation

/// `AgentLoop.GenerateNative` over the user's own command-line tool (`ConnectedTool`):
/// one run of the tool per loop turn, as a **text generator only**.
///
/// The tool runs with no tools of its own, so this writes the function list and the
/// call format into the prompt, in the Qwen3 `<tool_call>` shape `NativeToolCallParser`
/// reads. The loop, the taint rule, the approval cards and "only an executed tool
/// counts" stay in this app, exactly as for the endpoint.
///
/// - **The version is checked before every request.** A version other than the one the
///   Test passed on sends nothing: an update can change what the lean flags load, and
///   the user's hooks must never run on the chord's text.
/// - **The prompt goes on stdin** (`CLIProcess`). argv holds constants only.
/// - **The send is recorded before the launch**, as the endpoint does, so a failed run
///   still shows that text may have left. Counts only, never the content.
/// - **Every failure is nil**, the endpoint's rule: the loop then ends like a spent
///   budget, and the view model hands the words to the on-device tier.
struct ConnectedToolGenerator: Sendable {
    let kind: ConnectedTool.Kind
    let executable: URL
    /// The version whose Test passed (`ConnectedTool.tested`).
    let testedVersion: String
    let sent: EndpointSendLog
    /// Shorter than the loop's 30 s budget. About 4 s a turn on the probe.
    var timeout: TimeInterval = 20
    /// An answer is a sentence; the room is for a tool that prints one JSON line per event.
    var outputCap = 1 << 20
    var runner: CLIProcess.Runner = CLIProcess.live
    var environment = ConnectedTool.environment()
    /// The tool's name and a fixed phrase only. Never the prompt, never its output.
    var log: @Sendable (String) -> Void = { Log.connectors.notice("\($0, privacy: .public)") }

    init(kind: ConnectedTool.Kind, executable: URL, testedVersion: String, sent: EndpointSendLog) {
        self.kind = kind
        self.executable = executable
        self.testedVersion = testedVersion
        self.sent = sent
    }

    var generate: AgentLoop.GenerateNative {
        { messages, tools in await reply(messages, tools: tools) }
    }

    func reply(_ messages: [[String: String]], tools: [String]) async -> String? {
        let check = await runner(command(ConnectedTool.versionArguments), Data(), 5, 4_096)
        guard case .exited(0, let printed) = check,
              let version = ConnectedTool.version(from: printed, kind: kind) else {
            if case .couldNotStart = check {
                return fail(ConnectedTool.failure(check, kind: kind, timeout: 5))
            }
            return check == .cancelled ? nil : fail("did not report its version")
        }
        guard version == testedVersion else { return fail("changed version since its Test passed") }

        sent.record(Self.framed(messages), tools: tools)
        let outcome = await runner(command(ConnectedTool.arguments(kind)),
                                   Data(Self.prompt(messages, tools: tools, kind: kind).utf8),
                                   timeout, outputCap)
        if case .exited(0, let stdout) = outcome, let text = ConnectedTool.reply(from: stdout, kind: kind) {
            return text
        }
        return fail(ConnectedTool.failure(outcome, kind: kind, timeout: timeout))
    }

    private func command(_ arguments: [String]) -> CLIProcess.Command {
        CLIProcess.Command(executable: executable, arguments: arguments, environment: environment)
    }

    /// nil `reason` is a cancel: Escape or the loop's budget, which the loop reports.
    private func fail(_ reason: String?) -> String? {
        guard let reason else { return nil }
        sent.recordFailure(reason)
        log("Connected tool \(kind.name) \(reason).")
        return nil
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
    /// the conversation as labelled turns (the roles of `AgentLoop.wireMessages`). Claude
    /// gets `textOnlySystemPrompt` in argv; Codex has no such flag, so it leads here.
    static func prompt(_ messages: [[String: String]], tools: [String], kind: ConnectedTool.Kind) -> String {
        var rest = messages[...]
        var instructions = ""
        if rest.first?["role"] == "system" {
            instructions = rest.first?["content"] ?? ""
            rest = rest.dropFirst()
        }
        let conversation = rest.map { "[\(label($0["role"]))] \($0["content"] ?? "")" }
        return ((kind == .codex ? [ConnectedTool.textOnlySystemPrompt] : [])
            + [instructions, howToCall,
               (["<tools>"] + tools + ["</tools>"]).joined(separator: "\n"),
               (["# Conversation"] + conversation).joined(separator: "\n")])
            .joined(separator: "\n\n")
    }

    private static func label(_ role: String?) -> String {
        switch role {
        case "user": return "user"
        case "assistant": return "assistant"
        case "tool": return "function result"
        // A note from the loop in the middle of a run.
        default: return "app note"
        }
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
