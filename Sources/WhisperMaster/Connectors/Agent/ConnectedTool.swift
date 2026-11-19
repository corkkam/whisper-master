import Darwin
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
/// turn the tier on, and **the Test pins the file it ran** (`Binary`): an update, a
/// reinstall or a swap reads as untested until the Test passes again.
///
/// Persisted in `UserDefaults` as `{kind, consentedTo, paused, tested}`: no sign-in
/// state, nothing secret. A payload that does not decode reads as nothing connected,
/// the closed direction, so a field added later must be optional.
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

        /// The company the tool sends the text to, for the consent sheet.
        var vendor: String { self == .claudeCode ? "Anthropic" : "OpenAI" }

        /// Always passed. The lean flags skip the user's own settings, so without it
        /// Claude falls back to its largest model. `sonnet` is an alias and survives a
        /// model update.
        var model: String { self == .claudeCode ? "sonnet" : "gpt-6-luna" }

        var isAvailable: Bool { self == .claudeCode || FeatureFlags.connectedCodexAvailable }
    }

    /// The file that runs: the link's real target, with its size, change time and inode.
    /// A few `stat` calls, so the chord can compare it without starting anything.
    struct Binary: Codable, Equatable, Sendable {
        var path: String
        var size: Int64
        var modified: Double
        var inode: UInt64
    }

    /// A Test that passed: which tool, the version its start-up record gave, and the file.
    struct Tested: Codable, Equatable, Sendable {
        var kind: Kind
        var version: String
        /// Optional, so a record without one reads as untested rather than failing to load.
        var binary: Binary?
    }

    var kind: Kind?
    /// Consent is for one tool. Another tool asks again.
    var consentedTo: Kind?
    /// The tray's pause item. Paused, the tool is skipped.
    var paused = false
    /// **A changed file counts as untested.** A new version can change what the lean
    /// flags load, and the user's hooks must never run on the chord's text, so nothing is
    /// sent until the Test passes on the file that runs (`isUsable`). Each run also checks
    /// the version in its own start-up record (`StreamCheck`).
    var tested: Tested?

    var hasConsent: Bool { kind != nil && consentedTo == kind }

    var isTested: Bool { kind != nil && tested?.kind == kind }

    /// Ready to take a capture, as far as the stored choice says.
    var isActive: Bool { hasConsent && isTested && !paused && kind?.isAvailable == true }

    /// The kind, when this build offers it. A stored Codex while its flag is off is nil.
    var availableKind: Kind? { kind?.isAvailable == true ? kind : nil }

    /// On, and the file at the tool's place is the one the Test passed on. No spawn, so
    /// the chord can pick its tier with it, and a tool that changed leaves the choice to
    /// the endpoint.
    func isUsable(_ installed: Binary?) -> Bool {
        isActive && installed != nil && tested?.binary == installed
    }

    /// What is at the tool's place now: its path and its file.
    static func installed(_ tool: ConnectedTool) -> (path: URL, binary: Binary)? {
        guard let kind = tool.availableKind, let path = locate(kind), let binary = binary(at: path)
        else { return nil }
        return (path, binary)
    }

    // MARK: - Persistence

    static let defaultsKey = "WhisperMaster.connectedTool.v1"

    /// A kind this build does not offer (Codex while its flag is off) is dropped, so no
    /// stored value can reach it.
    static func load(from defaults: UserDefaults = .standard) -> ConnectedTool {
        var tool = defaults.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(ConnectedTool.self, from: $0) } ?? ConnectedTool()
        if tool.kind?.isAvailable == false { tool.kind = nil }
        if tool.consentedTo?.isAvailable == false { tool.consentedTo = nil }
        if tool.tested?.kind.isAvailable == false { tool.tested = nil }
        return tool
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
    /// by moving the link. Looked up again at each chord. A target anyone can write to is
    /// refused, because anyone could then choose what runs.
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

    /// The file at `url` after every link, or nil.
    static func binary(at url: URL) -> Binary? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        var info = stat()
        guard stat(resolved, &info) == 0 else { return nil }
        return Binary(path: String(cString: resolved), size: Int64(info.st_size),
                      modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
                      inode: UInt64(info.st_ino))
    }

    /// "~/.local/bin/claude" for Settings.
    static func displayPath(_ path: String,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    /// The child's whole environment. Nothing else passes: a dev build started from a
    /// terminal can carry an API key or a config folder of the tool's, and with them the
    /// tool may bill that key and not the user's own plan. HOME is how the tool finds
    /// its own sign-in. No Node.js folder is added: a tool that needs one fails with a
    /// clear reason (`failure`).
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

    /// The command line, for the Test and the chord alike. **Never `--bare`**: it skips
    /// the user's own sign-in. For Claude the lean flags are mandatory: without
    /// `--setting-sources ""` and `--strict-mcp-config` each call loads the user's hooks,
    /// MCP servers and skills (about 150k tokens), and the hooks write files; `--tools ""`
    /// alone still leaves every MCP tool. Each `""` is followed by a flag, because
    /// `--tools` takes a list. `stream-json` with hook events puts the start-up record
    /// and any hook on stdout, so every run can be checked as it starts (`StreamCheck`).
    static func arguments(_ kind: Kind) -> [String] {
        switch kind {
        case .claudeCode:
            return ["-p", "--model", kind.model, "--tools", "", "--no-session-persistence",
                    "--setting-sources", "", "--strict-mcp-config",
                    "--system-prompt", textOnlySystemPrompt,
                    "--output-format", "stream-json", "--verbose", "--include-hook-events"]
        case .codex:
            return ["exec", "-m", kind.model, "--sandbox", "read-only", "--ephemeral",
                    "--skip-git-repo-check", "--ignore-user-config", "--json", "-"]
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
        // `env` found no `node`: an npm install, which needs Node.js on a PATH the app
        // keeps fixed on purpose.
        case .exited(127, _):
            return "needs Node.js, which is not on the app's fixed PATH. The native installer's build does not"
        case .exited(let status, let stdout):
            return notSignedIn(stdout, kind: kind) ? "is not signed in" : "stopped with exit status \(status)"
        case .timedOut: return "did not answer within \(Int(timeout)) seconds"
        case .tooLarge: return "printed more than 1 MB"
        case .couldNotStart(let code): return "could not start (error \(code))"
        case .refused: return "printed something the app does not allow, so it was stopped"
        case .cancelled: return nil
        }
    }

    // MARK: - The start-up check, on every run

    /// Reads Claude's `stream-json` a line at a time, for the Test and for every chord
    /// run (`CLIProcess.LineCheck`), and refuses the run at the first line that a lean,
    /// tool-free run does not print. **Fail closed**: the first line must be the start-up
    /// record with no tools, no MCP servers and, on the chord, the version the Test passed
    /// on; every later line must be an event the app knows, and a model turn may hold
    /// text and thinking only. A hook event, an event the app does not know, or a line
    /// that is not JSON refuses the run. `problem` says why, in a fixed phrase.
    final class StreamCheck: @unchecked Sendable {
        private let lock = NSLock()
        private let expected: String?
        private var started: String?
        private var refusal: String?

        /// - Parameter version: the version the start-up record must show; nil at the
        ///   Test, which records whatever it shows.
        init(expecting version: String?) {
            expected = version
        }

        /// The version in the accepted start-up record, or nil before one.
        var version: String? {
            lock.lock()
            defer { lock.unlock() }
            return started
        }

        var problem: String? {
            lock.lock()
            defer { lock.unlock() }
            return refusal
        }

        func accept(_ line: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if refusal == nil { refusal = problem(in: line) }
            return refusal == nil
        }

        private func problem(in line: Data) -> String? {
            if line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) { return nil }
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = event["type"] as? String
            else { return "printed a line the app could not read" }
            let subtype = event["subtype"] as? String
            if subtype?.hasPrefix("hook_") == true { return "ran a hook of its own" }
            guard started != nil else {
                guard type == "system", subtype == "init" else {
                    return "printed something before its start-up record"
                }
                guard let tools = event["tools"] as? [Any], let servers = event["mcp_servers"] as? [Any] else {
                    return "started without saying which tools it loaded"
                }
                guard tools.isEmpty, servers.isEmpty else {
                    return "started with \(tools.count) tools and \(servers.count) MCP servers of its own"
                }
                guard let version = event["claude_code_version"] as? String, !version.isEmpty else {
                    return "started without saying its version"
                }
                if let expected, version != expected {
                    return "is a different version from the one its Test passed on"
                }
                started = version
                return nil
            }
            switch (type, subtype) {
            case ("system", "thinking_tokens"), ("rate_limit_event", _), ("result", _):
                return nil
            case ("assistant", _):
                let blocks = ((event["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
                let plain = blocks.allSatisfy {
                    ["text", "thinking", "redacted_thinking"].contains($0["type"] as? String ?? "")
                }
                return plain ? nil : "tried to use a tool of its own"
            default:
                return "printed an event the app does not know"
            }
        }
    }

    // MARK: - Detection and the Test (Settings only)

    struct Detection: Equatable, Sendable {
        var path: URL?
        var binary: Binary?
    }

    /// Found, and the file it is. File checks only: nothing starts, nothing is sent.
    static func detect(_ kind: Kind) -> Detection {
        guard kind.isAvailable, let path = locate(kind) else { return Detection() }
        return Detection(path: path, binary: binary(at: path))
    }

    enum TestResult: Equatable, Sendable {
        case passed(Tested)
        case notSignedIn
        /// It loaded or printed something of its own. The phrase says what.
        case notLean(String)
        /// The rest of a sentence about the tool, as `failure(_:kind:timeout:)` gives.
        case failed(String)
    }

    /// The Settings Test, on a tap only: it uses the user's plan. It runs the chord's own
    /// line with `testPrompt` under a `StreamCheck`, so what passes is what the chord
    /// will run, and **it proves the lean flags still hold**: zero tools, zero MCP
    /// servers, no hook event, nothing unknown. It pins the version the start-up record
    /// gave and the file that ran. Codex cannot pass: nothing can prove its shell is off.
    static func test(_ kind: Kind, at executable: URL,
                     runner: CLIProcess.Runner = CLIProcess.live) async -> TestResult {
        guard kind.isAvailable else { return .failed("is not offered in this build") }
        guard kind == .claudeCode else { return .failed("cannot prove it runs no commands of its own") }
        guard let before = binary(at: executable) else { return .failed("could not be found") }
        let check = StreamCheck(expecting: nil)
        let command = CLIProcess.Command(executable: executable, arguments: arguments(kind),
                                         environment: environment())
        let outcome = await runner(command, Data(testPrompt.utf8), 30, 1 << 20, { check.accept($0) })
        return verdict(outcome, check: check, kind: kind, before: before, after: binary(at: executable))
    }

    /// The Test's verdict on one run.
    static func verdict(_ outcome: CLIProcess.Outcome, check: StreamCheck, kind: Kind,
                        before: Binary, after: Binary?) -> TestResult {
        if let problem = check.problem { return .notLean(problem) }
        guard case .exited(let status, let stdout) = outcome else {
            return .failed(failure(outcome, kind: kind, timeout: 30) ?? "was stopped")
        }
        if notSignedIn(stdout, kind: kind) { return .notSignedIn }
        guard let version = check.version else { return .failed("printed no start-up record") }
        guard after == before else { return .failed("changed while the Test ran") }
        guard status == 0, reply(from: stdout, kind: kind) != nil else {
            return .failed(failure(outcome, kind: kind, timeout: 30) ?? "gave no answer the app could read")
        }
        return .passed(Tested(kind: kind, version: version, binary: before))
    }
}
