import Foundation

/// The user's own coding tool as the chord's brain (Settings → Assistant → Connected
/// tool, dev builds only, `FeatureFlags.agentEndpointAvailable`). **Text only.** The
/// tool runs as a text generator; the loop, the taint rule and the approval cards stay
/// in this app (`ConnectedToolGenerator`).
///
/// The app is a client of the tool and never ships, installs or updates it, the same
/// rule as kunai and Shed. It finds the binary in three fixed folders and starts it by
/// its absolute path. **It never reads the tool's sign-in**: the tool signs in with the
/// user's own account, as it does in a terminal. Finding it sends nothing. The Test
/// sends one fixed prompt, and only on a tap. Only a passed Test and the consent sheet
/// turn the tier on.
///
/// Persisted in `UserDefaults` as `{kind, consentedTo, paused, tested}`: no path, no
/// sign-in state, nothing secret. A payload that does not decode reads as nothing
/// connected, the closed direction, so a field added later must be optional.
struct ConnectedTool: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case claudeCode
        /// Built and tested, never reachable: in its read-only sandbox Codex still runs
        /// shell commands, so text from a mail could make it read a file and send it on.
        /// Off until a canary proves its shell is off (`FeatureFlags.connectedCodexAvailable`).
        case codex

        var id: String { rawValue }

        var tier: AgentTier { self == .claudeCode ? .claudeCode : .codex }

        /// The tool's own name, for a sentence about it. Never a feature name.
        var name: String { tier.remoteName ?? rawValue }

        var binary: String { self == .claudeCode ? "claude" : "codex" }

        /// Where the text goes next, for the consent sheet.
        var vendor: String {
            self == .claudeCode
                ? "Anthropic, under your Claude account"
                : "OpenAI, under your ChatGPT account"
        }

        /// Always passed. The lean flags skip the user's own settings, so without it
        /// Claude falls back to its largest model. `sonnet` is an alias and survives a
        /// model update.
        var model: String { self == .claudeCode ? "sonnet" : "gpt-6-luna" }

        var isAvailable: Bool { self == .claudeCode || FeatureFlags.connectedCodexAvailable }
    }

    /// A Test that passed: which tool, and the version it ran.
    struct Tested: Codable, Equatable, Sendable {
        var kind: Kind
        var version: String
    }

    var kind: Kind?
    /// Consent is for one tool. Another tool asks again.
    var consentedTo: Kind?
    /// The tray's pause item. Paused, the tool is skipped.
    var paused = false
    /// **An update counts as untested.** A new version can change what the lean flags
    /// load, and the user's hooks must never run on the chord's text, so nothing is sent
    /// until the Test passes on the version that runs. `ConnectedToolGenerator` checks
    /// the version again before every request.
    var tested: Tested?

    var hasConsent: Bool { kind != nil && consentedTo == kind }

    var isTested: Bool { kind != nil && tested?.kind == kind }

    /// Ready to take a capture, as far as the stored choice says. The binary and its
    /// version are checked at the chord.
    var isActive: Bool { hasConsent && isTested && !paused && kind?.isAvailable == true }

    // MARK: - Persistence

    static let defaultsKey = "WhisperMaster.connectedTool.v1"

    static func load(from defaults: UserDefaults = .standard) -> ConnectedTool {
        defaults.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(ConnectedTool.self, from: $0) } ?? ConnectedTool()
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    // MARK: - Finding it

    /// Searched in this order. An app started from Finder gets launchd's PATH, which has
    /// none of them, and a shell (`zsh -lc`, `env`) would read the user's dotfiles.
    static func folders(home: URL) -> [URL] {
        [home.appendingPathComponent(".local/bin"),
         URL(fileURLWithPath: "/opt/homebrew/bin"),
         URL(fileURLWithPath: "/usr/local/bin")]
    }

    /// The binary's path, or nil. The link, not its target: the tools update themselves
    /// by moving the link. Looked up again at each chord, never stored. A target anyone
    /// can write to is refused, because anyone could then choose what runs.
    static func locate(_ kind: Kind,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let files = FileManager.default
        for folder in folders(home: home) {
            let url = folder.appendingPathComponent(kind.binary)
            guard files.isExecutableFile(atPath: url.path),
                  let mode = (try? files.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.posixPermissions]
                    as? Int,
                  mode & 0o002 == 0
            else { continue }
            return url
        }
        return nil
    }

    /// "~/.local/bin/claude" for Settings.
    static func displayPath(_ url: URL,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
        return url.path.hasPrefix(prefix) ? "~/" + url.path.dropFirst(prefix.count) : url.path
    }

    /// The child's whole environment. Nothing else passes: a dev build started from a
    /// terminal can carry an API key or a config folder of the tool's, and with them the
    /// tool may bill that key and not the user's own plan. HOME is how the tool finds
    /// its own sign-in.
    static func environment(from parent: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        var environment = parent.filter { ["HOME", "USER", "LOGNAME", "TMPDIR"].contains($0.key) }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }

    // MARK: - The command lines (constants only: argv is readable by every process)

    /// Claude's `--system-prompt`. With its tools off, the model can still print
    /// `<invoke name="Bash">` as text; a text-only system prompt stops that. The
    /// `<tool_call>` format the app asks for is "the reply format in the user message".
    static let textOnlySystemPrompt = "You write text only. You have no tools of your own: you "
        + "cannot run commands, read files or open links. Never write <invoke> or "
        + "<function_calls> markup. When the user message gives a reply format, follow it exactly."

    static let testPrompt = "Reply with the word OK."

    static let versionArguments = ["--version"]

    /// The chord's command line. **Never `--bare`**: it skips the user's own sign-in.
    /// For Claude the lean flags are mandatory: without `--setting-sources ""` and
    /// `--strict-mcp-config` each call loads the user's hooks, MCP servers and skills
    /// (about 150k tokens), and the hooks write files. `--tools ""` alone still leaves
    /// every MCP tool. Each `""` is followed by a flag, because `--tools` takes a list.
    static func arguments(_ kind: Kind) -> [String] {
        switch kind {
        case .claudeCode:
            return ["-p", "--model", kind.model, "--tools", "", "--no-session-persistence",
                    "--setting-sources", "", "--strict-mcp-config",
                    "--system-prompt", textOnlySystemPrompt, "--output-format", "json"]
        case .codex:
            return ["exec", "-m", kind.model, "--sandbox", "read-only", "--ephemeral",
                    "--skip-git-repo-check", "--ignore-user-config", "--json", "-"]
        }
    }

    /// The Test's command line: the chord's, with stream-json so the start-up record
    /// shows what loaded, and hook events so a hook that ran shows too.
    static func testArguments(_ kind: Kind) -> [String] {
        switch kind {
        case .claudeCode:
            return arguments(kind).dropLast(2)
                + ["--output-format", "stream-json", "--verbose", "--include-hook-events"]
        case .codex:
            return arguments(kind)
        }
    }

    // MARK: - Reading what it printed

    /// The model's final text, trimmed, or nil. Pure; the loop reads `<tool_call>` out
    /// of the text, and this never does.
    ///
    /// **The no-tool guard.** Nil when the output shows the tool ran a tool of its own
    /// or wrote tool markup: more than one turn, a permission denial, `<invoke` or
    /// `<function_calls` (Claude); any item but a message or reasoning (Codex). The run
    /// is then a failure, never an answer. For Codex this acts only after the command
    /// ran, which is why Codex stays behind its own flag.
    static func reply(from stdout: Data, kind: Kind) -> String? {
        switch kind {
        case .claudeCode:
            return claudeResult(stdout).flatMap(claudeAnswer)
        case .codex:
            return codexAnswer(events(stdout))
        }
    }

    /// The tool said it is not signed in. Claude only: Codex's shape was never seen.
    static func notSignedIn(_ stdout: Data, kind: Kind) -> Bool {
        guard kind == .claudeCode, let result = claudeResult(stdout) else { return false }
        return result["is_error"] as? Bool == true
            && (result["result"] as? String)?.hasPrefix("Not logged in") == true
    }

    /// "2.1.328 (Claude Code)" → "2.1.328"; "codex-cli 0.170.0" → "0.170.0".
    static func version(from stdout: Data, kind: Kind) -> String? {
        let line = String(decoding: stdout.prefix(256), as: UTF8.self)
            .split(whereSeparator: \.isNewline).first ?? ""
        let words = line.split(separator: " ")
        guard let word = kind == .claudeCode ? words.first : words.last,
              word.first?.isNumber == true, word.count <= 40
        else { return nil }
        return String(word)
    }

    /// Claude's `result` object, from `json` (one object) or `stream-json` (the last
    /// `result` line).
    private static func claudeResult(_ stdout: Data) -> [String: Any]? {
        if let object = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any] {
            return object
        }
        return events(stdout).last { $0["type"] as? String == "result" }
    }

    /// Accepted only when `is_error` is false and `terminal_reason` is "completed". Not
    /// `subtype`: a run that was not signed in says "success" there.
    private static func claudeAnswer(_ result: [String: Any]) -> String? {
        guard result["type"] as? String == "result",
              result["is_error"] as? Bool == false,
              result["terminal_reason"] as? String == "completed",
              result["num_turns"] as? Int == 1,
              (result["permission_denials"] as? [Any])?.isEmpty ?? true
        else { return nil }
        return text(result["result"] as? String)
    }

    /// The last message, not the first: a run that ran a command says what it will do
    /// before it does it.
    private static func codexAnswer(_ events: [[String: Any]]) -> String? {
        var answer: String?
        for event in events {
            let type = event["type"] as? String
            let item = event["item"] as? [String: Any]
            if type == "turn.failed" || type == "error" { return nil }
            guard let item else { continue }
            switch item["type"] as? String {
            case "agent_message":
                if type == "item.completed" { answer = item["text"] as? String }
            case "reasoning":
                continue
            default:
                return nil  // a command, a file change, a search, an error
            }
        }
        return text(answer)
    }

    private static func text(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              !trimmed.contains("<invoke"), !trimmed.contains("<function_calls")
        else { return nil }
        return trimmed
    }

    /// One JSON object per line; a line that is not one is skipped.
    private static func events(_ stdout: Data) -> [[String: Any]] {
        stdout.split(separator: UInt8(ascii: "\n")).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
        }
    }

    /// Why a run gave no answer, as the rest of a sentence about the tool ("Claude Code
    /// did not answer within 20 seconds"). A fixed phrase, never the tool's own output.
    /// nil for a cancel: the loop reports that.
    static func failure(_ outcome: CLIProcess.Outcome, kind: Kind, timeout: TimeInterval) -> String? {
        switch outcome {
        case .exited(0, _): return "gave no answer the app could read"
        case .exited(let status, let stdout):
            return notSignedIn(stdout, kind: kind) ? "is not signed in" : "stopped with exit status \(status)"
        case .timedOut: return "did not answer within \(Int(timeout)) seconds"
        case .tooLarge: return "printed more than 1 MB"
        case .couldNotStart(let code): return "could not start (error \(code))"
        case .cancelled: return nil
        }
    }

    // MARK: - Detection and the Test (Settings only)

    struct Detection: Equatable, Sendable {
        var path: URL?
        var version: String?
    }

    /// Found, and the version it reports. `--version` runs on this Mac only and sends
    /// nothing.
    static func detect(_ kind: Kind, runner: CLIProcess.Runner = CLIProcess.live) async -> Detection {
        guard let path = locate(kind) else { return Detection() }
        return Detection(path: path, version: await version(of: path, kind: kind, runner: runner))
    }

    static func version(of executable: URL, kind: Kind,
                        runner: CLIProcess.Runner = CLIProcess.live) async -> String? {
        let command = CLIProcess.Command(executable: executable, arguments: versionArguments,
                                         environment: environment())
        guard case .exited(0, let stdout) = await runner(command, Data(), 5, 4_096) else { return nil }
        return version(from: stdout, kind: kind)
    }

    enum TestResult: Equatable, Sendable {
        case passed(version: String)
        case notSignedIn
        /// It started with something of its own loaded. The phrase says what.
        case notLean(String)
        /// The rest of a sentence about the tool, as `failure(_:kind:timeout:)` gives.
        case failed(String)
    }

    /// The Settings Test, on a tap only: it uses the user's plan. `--version`, then the
    /// chord's line with `testPrompt`, so what passes is what the chord will run.
    /// **For Claude it also proves the lean flags still hold** on this version: zero
    /// tools, zero MCP servers and no hook event in the start-up record. For Codex it
    /// checks the answer only; it cannot prove the shell is off.
    static func test(_ kind: Kind, at executable: URL,
                     runner: CLIProcess.Runner = CLIProcess.live) async -> TestResult {
        guard let version = await version(of: executable, kind: kind, runner: runner) else {
            return .failed("did not report its version")
        }
        let command = CLIProcess.Command(executable: executable, arguments: testArguments(kind),
                                         environment: environment())
        let outcome = await runner(command, Data(testPrompt.utf8), 30, 1 << 20)
        guard case .exited(let status, let stdout) = outcome else {
            return .failed(failure(outcome, kind: kind, timeout: 30) ?? "was stopped")
        }
        return check(stdout, status: status, kind: kind, version: version)
    }

    /// The Test's verdict on what the tool printed. Pure, so the probe's own output pins it.
    static func check(_ stdout: Data, status: Int32, kind: Kind, version: String) -> TestResult {
        if notSignedIn(stdout, kind: kind) { return .notSignedIn }
        if kind == .claudeCode {
            let events = events(stdout)
            guard let start = events.first(where: {
                $0["type"] as? String == "system" && $0["subtype"] as? String == "init"
            }) else { return .failed("printed no start-up record") }
            // Missing reads as loaded: the closed direction.
            let tools = (start["tools"] as? [Any])?.count ?? -1
            let servers = (start["mcp_servers"] as? [Any])?.count ?? -1
            let hooks = events.filter { ($0["subtype"] as? String)?.hasPrefix("hook_") == true }.count
            guard tools == 0, servers == 0, hooks == 0 else {
                return .notLean("started with \(max(tools, 0)) tools, \(max(servers, 0)) MCP servers "
                    + "and \(hooks) hook events of its own")
            }
            guard start["claude_code_version"] as? String == version else {
                return .failed("changed version during the Test")
            }
        }
        guard status == 0, reply(from: stdout, kind: kind) != nil else {
            return .failed(failure(.exited(status: status, stdout: stdout), kind: kind, timeout: 30)
                ?? "gave no answer the app could read")
        }
        return .passed(version: version)
    }
}
