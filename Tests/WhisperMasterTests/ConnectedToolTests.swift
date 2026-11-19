import XCTest

@testable import WhisperMaster

/// The connected tool tier: what it stores, how it finds the binary, the command lines,
/// the parser and its no-tool guard, and the Settings Test. The fixtures are the CLI
/// probe's real outputs (2026-11-19, Claude Code 2.1.328, codex-cli 0.170.0), trimmed to
/// the keys the parser reads. No test starts the real `claude` or `codex`.
final class ConnectedToolTests: XCTestCase {
    // MARK: - Fixtures

    /// `c1.json`: a lean run that answered.
    static let claudeOK = Data(#"""
    {"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed",
     "num_turns":1,"permission_denials":[],"result":"OK"}
    """#.utf8)

    /// `c2.json`: `--bare`, not signed in. `subtype` still says "success".
    static let claudeNotSignedIn = Data(#"""
    {"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error",
     "num_turns":1,"permission_denials":[],"result":"Not logged in · Please run /login"}
    """#.utf8)

    static func claude(result: String, turns: Int = 1, denials: String = "[]") -> Data {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: [result]), as: UTF8.self)
        return Data(#"""
        {"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed",
         "num_turns":\#(turns),"permission_denials":\#(denials),"result":\#(text.dropFirst().dropLast())}
        """#.utf8)
    }

    /// `x1.jsonl`.
    static let codexOK = Data(#"""
    {"type":"thread.started","thread_id":"t"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"OK"}}
    {"type":"turn.completed","usage":{}}
    """#.utf8)

    /// `x4.jsonl`: it ran `ls` in its read-only sandbox, then answered.
    static let codexRanACommand = Data(#"""
    {"type":"thread.started","thread_id":"t"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I'll list the current folder's entries."}}
    {"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'ls -la'","status":"in_progress"}}
    {"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'ls -la'","aggregated_output":"a.txt","exit_code":0,"status":"completed"}}
    {"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"The current folder contains a.txt and b.txt."}}
    {"type":"turn.completed","usage":{}}
    """#.utf8)

    /// `x6.jsonl`: a model a ChatGPT sign-in cannot use.
    static let codexTurnFailed = Data(#"""
    {"type":"thread.started","thread_id":"t"}
    {"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata not found."}}
    {"type":"turn.started"}
    {"type":"error","message":"The model is not supported."}
    {"type":"turn.failed","error":{"message":"The model is not supported."}}
    """#.utf8)

    /// `c5.jsonl`: the lean Test line's stream, init and result kept.
    static func leanStream(version: String = "2.1.328", tools: String = "[]",
                           servers: String = "[]", hooks: Bool = false, answer: String = "OK") -> Data {
        var lines = [
            #"{"type":"system","subtype":"init","tools":\#(tools),"mcp_servers":\#(servers),"claude_code_version":"\#(version)","model":"claude-sonnet-5-5"}"#,
            #"{"type":"assistant","message":{}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","num_turns":1,"permission_denials":[],"result":"\#(answer)"}"#,
        ]
        // `c4.jsonl`: without the lean flags, the user's hooks run before the start-up record.
        if hooks {
            lines.insert(#"{"type":"system","subtype":"hook_started","hook_event":"SessionStart","hook_name":"x"}"#, at: 0)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    // MARK: - Parsing, and the no-tool guard

    func testClaudesAnswerIsItsResult() {
        XCTAssertEqual(ConnectedTool.reply(from: Self.claudeOK, kind: .claudeCode), "OK")
    }

    /// The not-signed-in run says `subtype: "success"`. Trusting `subtype` would read
    /// "Not logged in" as the answer.
    func testANotSignedInRunIsNoAnswerWhateverItsSubtypeSays() {
        XCTAssertNil(ConnectedTool.reply(from: Self.claudeNotSignedIn, kind: .claudeCode))
        XCTAssertTrue(ConnectedTool.notSignedIn(Self.claudeNotSignedIn, kind: .claudeCode))
        XCTAssertFalse(ConnectedTool.notSignedIn(Self.claudeOK, kind: .claudeCode))
        XCTAssertEqual(ConnectedTool.failure(.exited(status: 1, stdout: Self.claudeNotSignedIn),
                                             kind: .claudeCode, timeout: 20),
                       "is not signed in")
    }

    func testToolMarkupOrAToolTurnIsNeverAnAnswer() {
        XCTAssertNil(ConnectedTool.reply(from: Self.claude(result: #"<invoke name="Bash">ls -la</invoke>"#),
                                         kind: .claudeCode))
        XCTAssertNil(ConnectedTool.reply(from: Self.claude(result: "<function_calls>x</function_calls>"),
                                         kind: .claudeCode))
        XCTAssertNil(ConnectedTool.reply(from: Self.claude(result: "Done.", turns: 2), kind: .claudeCode))
        XCTAssertNil(ConnectedTool.reply(from: Self.claude(result: "Done.", denials: #"[{"tool_name":"Bash"}]"#),
                                         kind: .claudeCode))
        XCTAssertNil(ConnectedTool.reply(from: Self.claude(result: "   "), kind: .claudeCode))
        XCTAssertNil(ConnectedTool.reply(from: Data("not json".utf8), kind: .claudeCode))
    }

    /// The parser never reads a call: the loop does, with `NativeToolCallParser`.
    func testAToolCallInTheTextComesBackUnchangedForTheLoop() {
        let call = #"<tool_call>{"name": "create_note", "arguments": {"body": "buy milk"}}</tool_call>"#
        XCTAssertEqual(ConnectedTool.reply(from: Self.claude(result: call), kind: .claudeCode), call)
    }

    func testCodexsAnswerIsItsLastMessage() {
        XCTAssertEqual(ConnectedTool.reply(from: Self.codexOK, kind: .codex), "OK")
    }

    /// The answer after a command is not taken: the command already read the folder.
    func testACodexRunThatRanACommandIsNoAnswer() {
        XCTAssertNil(ConnectedTool.reply(from: Self.codexRanACommand, kind: .codex))
        XCTAssertNil(ConnectedTool.reply(from: Self.codexTurnFailed, kind: .codex))
    }

    func testTheVersionIsReadFromEachToolsOwnLine() {
        XCTAssertEqual(ConnectedTool.version(from: Data("2.1.328 (Claude Code)\n".utf8), kind: .claudeCode),
                       "2.1.328")
        XCTAssertEqual(ConnectedTool.version(from: Data("codex-cli 0.170.0\n".utf8), kind: .codex), "0.170.0")
        XCTAssertNil(ConnectedTool.version(from: Data("Usage: claude [options]".utf8), kind: .claudeCode))
        XCTAssertNil(ConnectedTool.version(from: Data(), kind: .claudeCode))
    }

    func testEachOutcomeHasAFixedReason() {
        let cases: [(CLIProcess.Outcome, String?)] = [
            (.exited(status: 0, stdout: Data("garbage".utf8)), "gave no answer the app could read"),
            (.exited(status: 3, stdout: Data()), "stopped with exit status 3"),
            (.timedOut, "did not answer within 20 seconds"),
            (.tooLarge, "printed more than 1 MB"),
            (.couldNotStart(errno: ENOENT), "could not start (error 2)"),
            (.cancelled, nil),
        ]
        for (outcome, reason) in cases {
            XCTAssertEqual(ConnectedTool.failure(outcome, kind: .claudeCode, timeout: 20), reason, "\(outcome)")
        }
    }

    // MARK: - Command lines and environment

    func testClaudesLineIsTheLeanOneAndNeverBare() {
        let arguments = ConnectedTool.arguments(.claudeCode)
        for flag in ["-p", "--model", "--tools", "--no-session-persistence", "--setting-sources",
                     "--strict-mcp-config", "--system-prompt", "--output-format"] {
            XCTAssertTrue(arguments.contains(flag), flag)
        }
        XCTAssertFalse(arguments.contains("--bare"), "--bare skips the user's own sign-in")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--model")! + 1], "sonnet")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--output-format")! + 1], "json")
        // `--tools` takes a list: the empty value must be followed by a flag, or it
        // would swallow the next value as a tool name.
        for flag in ["--tools", "--setting-sources"] {
            let index = arguments.firstIndex(of: flag)!
            XCTAssertEqual(arguments[index + 1], "")
            XCTAssertTrue(arguments[index + 2].hasPrefix("--"), flag)
        }
        XCTAssertFalse(ConnectedTool.testArguments(.claudeCode).contains("--bare"))
    }

    func testTheTestLineIsTheChordsLineWithStreamJSON() {
        let chord = ConnectedTool.arguments(.claudeCode)
        let test = ConnectedTool.testArguments(.claudeCode)
        XCTAssertEqual(Array(test.prefix(chord.count - 2)), Array(chord.dropLast(2)))
        XCTAssertEqual(Array(test.suffix(4)), ["--output-format", "stream-json", "--verbose",
                                               "--include-hook-events"])
    }

    /// Only these keys pass: a dev build started from a terminal can carry an API key,
    /// and the tool would bill it instead of the user's own plan.
    func testTheEnvironmentIsAnAllowlist() {
        let parent = ["HOME": "/Users/u", "USER": "u", "LOGNAME": "u", "TMPDIR": "/tmp/u/",
                      "PATH": "/opt/homebrew/bin:/usr/bin", "ANTHROPIC_API_KEY": "sk-canary",
                      "OPENAI_API_KEY": "sk-canary", "CLAUDE_CONFIG_DIR": "/x", "CLAUDE_CODE_USE_BEDROCK": "1",
                      "CODEX_HOME": "/x", "SSH_AUTH_SOCK": "/x", "DYLD_INSERT_LIBRARIES": "/x",
                      "HTTPS_PROXY": "http://x", "WM_ENDPOINT_KEY": "x", "KUNAI_URL": "x"]
        XCTAssertEqual(ConnectedTool.environment(from: parent),
                       ["HOME": "/Users/u", "USER": "u", "LOGNAME": "u", "TMPDIR": "/tmp/u/",
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    // MARK: - Finding it

    func testLocateFindsTheBinaryInTheHomeBinFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\n".utf8).write(to: claude)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: claude.path)
        XCTAssertNotEqual(ConnectedTool.locate(.claudeCode, home: home), claude, "not executable")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        XCTAssertEqual(ConnectedTool.locate(.claudeCode, home: home), claude)
        XCTAssertEqual(ConnectedTool.displayPath(claude, home: home), "~/.local/bin/claude")

        // Anyone could choose what runs.
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: claude.path)
        XCTAssertNotEqual(ConnectedTool.locate(.claudeCode, home: home), claude, "world-writable")
    }

    /// A link to a world-writable file is refused too: the target is what runs.
    func testLocateJudgesTheLinksTarget() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        let versions = home.appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        let target = versions.appendingPathComponent("2.1.328")
        try Data("#!/bin/sh\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let link = bin.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(ConnectedTool.locate(.claudeCode, home: home), link, "the link, not its target")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: target.path)
        XCTAssertNotEqual(ConnectedTool.locate(.claudeCode, home: home), link)
    }

    // MARK: - What is stored

    private func defaults() -> UserDefaults {
        let name = "ConnectedToolTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testNothingIsOnUntilTestedAllowedAndUnpaused() {
        var tool = ConnectedTool(kind: .claudeCode)
        XCTAssertFalse(tool.isActive)
        tool.tested = .init(kind: .claudeCode, version: "2.1.328")
        XCTAssertFalse(tool.isActive, "tested, not allowed")
        tool.consentedTo = .claudeCode
        XCTAssertTrue(tool.isActive)
        tool.paused = true
        XCTAssertFalse(tool.isActive)
        XCTAssertFalse(ConnectedTool().isActive)
    }

    /// Consent and a Test are for one tool; another tool asks and tests again.
    func testAnotherToolAsksAgain() {
        var tool = ConnectedTool(kind: .claudeCode, consentedTo: .claudeCode,
                                 tested: .init(kind: .claudeCode, version: "2.1.328"))
        tool.kind = .codex
        XCTAssertFalse(tool.hasConsent)
        XCTAssertFalse(tool.isTested)
        XCTAssertFalse(tool.isActive)
    }

    func testCodexIsNeverReachable() {
        for channel in [ReleaseChannel.stable, .beta, .dev] {
            XCTAssertFalse(FeatureFlags.connectedCodexAvailable(on: channel), "\(channel)")
        }
        XCTAssertFalse(ConnectedTool.Kind.codex.isAvailable)
        let tool = ConnectedTool(kind: .codex, consentedTo: .codex, tested: .init(kind: .codex, version: "0.170.0"))
        XCTAssertFalse(tool.isActive, "consent and a Test must not reach Codex while its flag is off")
    }

    func testItRoundTripsAndABadPayloadReadsAsNothingConnected() {
        let store = defaults()
        let tool = ConnectedTool(kind: .claudeCode, consentedTo: .claudeCode, paused: true,
                                 tested: .init(kind: .claudeCode, version: "2.1.328"))
        tool.save(to: store)
        XCTAssertEqual(ConnectedTool.load(from: store), tool)

        store.set(Data(#"{"kind":"gemini","consentedTo":"gemini","paused":false}"#.utf8),
                  forKey: ConnectedTool.defaultsKey)
        XCTAssertEqual(ConnectedTool.load(from: store), ConnectedTool())
        store.set(Data("not json".utf8), forKey: ConnectedTool.defaultsKey)
        XCTAssertEqual(ConnectedTool.load(from: store), ConnectedTool())
    }

    // MARK: - The Settings Test

    func testTheLeanStreamPasses() {
        XCTAssertEqual(ConnectedTool.check(Self.leanStream(), status: 0, kind: .claudeCode, version: "2.1.328"),
                       .passed(version: "2.1.328"))
    }

    /// The case the Test exists for: an update that stops honouring the lean flags.
    func testAToolThatLoadsAnythingOfItsOwnFailsTheTest() {
        let mcp = ConnectedTool.check(Self.leanStream(tools: #"["mcp__x__y"]"#, servers: #"[{"name":"x"}]"#),
                                      status: 0, kind: .claudeCode, version: "2.1.328")
        XCTAssertEqual(mcp, .notLean("started with 1 tools, 1 MCP servers and 0 hook events of its own"))
        let hooks = ConnectedTool.check(Self.leanStream(hooks: true), status: 0, kind: .claudeCode,
                                        version: "2.1.328")
        guard case .notLean = hooks else { return XCTFail("\(hooks)") }
        // A start-up record with no tool list reads as loaded.
        let stream = Data(#"{"type":"system","subtype":"init","claude_code_version":"2.1.328"}"#.utf8)
        guard case .notLean = ConnectedTool.check(stream, status: 0, kind: .claudeCode, version: "2.1.328")
        else { return XCTFail("a missing tool list must not pass") }
    }

    func testTheTestFailsWithoutAStartUpRecordOrOnAnotherVersion() {
        XCTAssertEqual(ConnectedTool.check(Self.claudeOK, status: 0, kind: .claudeCode, version: "2.1.328"),
                       .failed("printed no start-up record"))
        XCTAssertEqual(ConnectedTool.check(Self.leanStream(version: "2.1.329"), status: 0, kind: .claudeCode,
                                           version: "2.1.328"),
                       .failed("changed version during the Test"))
        XCTAssertEqual(ConnectedTool.check(Self.claudeNotSignedIn, status: 1, kind: .claudeCode, version: "2.1.328"),
                       .notSignedIn)
    }

    /// The whole Test against a scripted runner: `--version`, then the test line with the
    /// fixed prompt on stdin.
    func testTheTestRunsTheVersionThenTheFixedPrompt() async {
        let calls = Calls()
        let runner: CLIProcess.Runner = { command, stdin, _, _ in
            calls.add(command.arguments, stdin)
            return command.arguments == ["--version"]
                ? .exited(status: 0, stdout: Data("2.1.328 (Claude Code)\n".utf8))
                : .exited(status: 0, stdout: Self.leanStream())
        }
        let result = await ConnectedTool.test(.claudeCode, at: URL(fileURLWithPath: "/fake/claude"), runner: runner)

        XCTAssertEqual(result, .passed(version: "2.1.328"))
        XCTAssertEqual(calls.all.map(\.arguments), [["--version"], ConnectedTool.testArguments(.claudeCode)])
        XCTAssertEqual(calls.all.last?.stdin, Data(ConnectedTool.testPrompt.utf8))
    }

    func testATestWithNoVersionStopsBeforeAnythingIsSent() async {
        let calls = Calls()
        let runner: CLIProcess.Runner = { command, stdin, _, _ in
            calls.add(command.arguments, stdin)
            return .exited(status: 1, stdout: Data())
        }
        let result = await ConnectedTool.test(.claudeCode, at: URL(fileURLWithPath: "/fake/claude"), runner: runner)
        XCTAssertEqual(result, .failed("did not report its version"))
        XCTAssertEqual(calls.all.count, 1)
    }

    // MARK: - Never the tool's sign-in

    /// The app starts the tool and never reads its sign-in. These names are where a
    /// sign-in lives; none may appear in the tier's source.
    func testTheTierNeverTouchesASignIn() throws {
        let agent = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WhisperMaster/Connectors/Agent")
        for file in ["ConnectedTool.swift", "CLIProcess.swift"] {
            let source = try String(contentsOf: agent.appendingPathComponent(file), encoding: .utf8)
            for word in ["SecItem", "Keychain", "auth.json", ".credentials", "ConnectorCredentials",
                         ".claude/", ".codex/"] {
                XCTAssertFalse(source.contains(word), "\(file) mentions \(word)")
            }
        }
    }
}

/// What a scripted runner was asked to run.
final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(arguments: [String], stdin: Data)] = []

    func add(_ arguments: [String], _ stdin: Data) {
        lock.lock()
        defer { lock.unlock() }
        calls.append((arguments, stdin))
    }

    var all: [(arguments: [String], stdin: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
