import XCTest

@testable import WhisperMaster

/// `CLIProcess` against a fake command-line tool: a shell script each test writes into
/// a temporary folder. No test starts the real `claude` or `codex`.
final class CLIProcessTests: XCTestCase {
    /// `fake-cli <mode> [arg]`. The environment is scrubbed, so the mode comes from argv.
    static let fakeCLI = """
    #!/bin/sh
    mode="$1"; arg="$2"
    case "$mode" in
      reply)   cat >/dev/null; cat "$arg" ;;
      echo)    cat ;;
      sleep)   cat >/dev/null; sleep 60 & echo $! >"$arg"; wait ;;
      garbage) cat >/dev/null; printf 'not json' ;;
      exit)    cat >/dev/null; exit 3 ;;
      huge)    cat >/dev/null; yes 'xxxxxxxxxxxxxxxx' ;;
      env)     cat >/dev/null; env ;;
      pwd)     cat >/dev/null; pwd; ls -A | wc -l ;;
      nostdin) sleep 0.2; echo ok ;;
    esac
    """

    /// Written once per class: macOS checks a newly written executable on its first
    /// run, which can take longer than the short timeouts below.
    private static let scriptFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("cli-process-\(UUID())")
    private static let script = Result { try writeFakeCLI(in: scriptFolder) }

    private var folder: URL!
    private var cli: URL!

    override class func tearDown() {
        try? FileManager.default.removeItem(at: scriptFolder)
        super.tearDown()
    }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("cli-process-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        cli = try Self.script.get()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Shared with `ConnectedToolTests`, which runs the Test against the same script.
    static func writeFakeCLI(in folder: URL, name: String = "fake-cli") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try fakeCLI.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func command(_ mode: String, _ arg: String? = nil) -> CLIProcess.Command {
        CLIProcess.Command(executable: cli, arguments: [mode] + (arg.map { [$0] } ?? []),
                           environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    private func run(_ mode: String, _ arg: String? = nil, stdin: Data = Data(),
                     timeout: TimeInterval = 5, cap: Int = 1 << 20) async -> CLIProcess.Outcome {
        await CLIProcess.run(command(mode, arg), stdin: stdin, timeout: timeout, outputCap: cap)
    }

    /// The pid the `sleep` mode wrote is gone. A killed orphan is reaped by launchd a
    /// moment later, and until then it still answers `kill(pid, 0)`.
    private func assertGone(_ pidFile: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let text = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), file: file, line: line)
        for _ in 0..<40 where kill(pid, 0) == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(kill(pid, 0), -1, "the grandchild \(pid) outlived the run", file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }

    func testStdinComesBackOnStdout() async {
        let outcome = await run("echo", stdin: Data("hello over stdin".utf8))
        XCTAssertEqual(outcome, .exited(status: 0, stdout: Data("hello over stdin".utf8)))
    }

    func testATimeoutStopsTheWholeGroup() async throws {
        let pidFile = folder.appendingPathComponent("pid")
        let started = Date()
        let outcome = await run("sleep", pidFile.path, timeout: 0.5)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
        try await assertGone(pidFile)
    }

    func testACancelStopsTheWholeGroup() async throws {
        let pidFile = folder.appendingPathComponent("pid")
        let command = command("sleep", pidFile.path)
        let task = Task { await CLIProcess.run(command, stdin: Data(), timeout: 30, outputCap: 1 << 20) }
        // Cancel once the grandchild exists, so the group kill has something to reach.
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let cancelled = Date()
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 2)
        try await assertGone(pidFile)
    }

    func testATaskCancelledBeforeTheRunStartsNothing() async {
        let command = command("echo")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await CLIProcess.run(command, stdin: Data("x".utf8), timeout: 5, outputCap: 1 << 20)
        }
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testOutputThatIsNotJSONComesBackAsItIs() async {
        let outcome = await run("garbage")
        XCTAssertEqual(outcome, .exited(status: 0, stdout: Data("not json".utf8)))
    }

    func testANonZeroExitIsReported() async {
        let outcome = await run("exit")
        XCTAssertEqual(outcome, .exited(status: 3, stdout: Data()))
    }

    /// The run returns only after the reap, so its return is the proof the child is gone.
    func testOutputPastTheCapStopsTheRun() async {
        let started = Date()
        let outcome = await run("huge", cap: 64 * 1024)
        XCTAssertEqual(outcome, .tooLarge)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    /// Without `F_SETNOSIGPIPE`, the write to a child that exited without reading sends
    /// SIGPIPE to the test process, and the default action ends it.
    func testAChildThatNeverReadsItsInputDoesNotEndTheApp() async {
        let outcome = await run("nostdin", stdin: Data(count: 1 << 20))
        XCTAssertEqual(outcome, .exited(status: 0, stdout: Data("ok\n".utf8)))
    }

    func testOnlyTheGivenEnvironmentReachesTheChild() async {
        setenv("ANTHROPIC_API_KEY", "sk-canary-cli-process", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        guard case .exited(0, let stdout) = await run("env") else { return XCTFail("env did not run") }
        let text = String(decoding: stdout, as: UTF8.self)
        XCTAssertFalse(text.contains("ANTHROPIC_API_KEY"), text)
        XCTAssertFalse(text.contains("HOME="), "only what the command carries: \(text)")
        XCTAssertTrue(text.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), text)
    }

    func testTheChildRunsInAnEmptyFolderThatIsRemovedAfter() async throws {
        guard case .exited(0, let stdout) = await run("pwd") else { return XCTFail("pwd did not run") }
        let lines = String(decoding: stdout, as: UTF8.self).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let path = try XCTUnwrap(lines.first)
        XCTAssertTrue(URL(fileURLWithPath: path).lastPathComponent.hasPrefix("wm-cli-"), path)
        XCTAssertEqual(lines.last, "0", "the folder held something before the run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the folder outlived the run")
    }

    /// The loop is on the main actor, and a run takes seconds: it must not stop the UI.
    @MainActor
    func testTheMainActorKeepsRunningDuringARun() async throws {
        let pidFile = folder.appendingPathComponent("pid")
        async let outcome = CLIProcess.run(command("sleep", pidFile.path), stdin: Data(),
                                           timeout: 1, outputCap: 1 << 20)
        var ticks = 0
        let started = Date()
        while Date().timeIntervalSince(started) < 0.8 {
            try await Task.sleep(nanoseconds: 20_000_000)
            ticks += 1
        }
        let finished = await outcome
        XCTAssertEqual(finished, .timedOut)
        XCTAssertGreaterThan(ticks, 10, "the main actor stalled during the run")
    }

    func testAMissingProgramCouldNotStart() async {
        let missing = CLIProcess.Command(executable: folder.appendingPathComponent("missing"),
                                         arguments: [], environment: [:])
        let outcome = await CLIProcess.run(missing, stdin: Data(), timeout: 5, outputCap: 1024)
        XCTAssertEqual(outcome, .couldNotStart(errno: ENOENT))
    }
}
