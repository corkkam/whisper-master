import XCTest

@testable import WhisperMaster

/// `CLIProcess` against a fake command-line tool: a shell script each test writes into
/// a temporary folder. No test starts the real `claude` or `codex`.
final class CLIProcessTests: XCTestCase {
    /// `fake-cli <mode> [arg]`. The environment is scrubbed, so the mode comes from argv.
    /// `late` and `hang` leave a grandchild in a group of its own (`setpgrp`), which the
    /// group kill cannot reach, holding stdout after the leader exits.
    static let fakeCLI = """
    #!/bin/sh
    mode="$1"; arg="$2"
    case "$mode" in
      marker)  touch "$arg"; cat ;;
      echo)    cat ;;
      late)    cat >/dev/null; perl -e 'setpgrp(0,0); select(undef,undef,undef,0.6); print "tail\\n"' &
               sleep 0.1; echo head ;;
      hang)    cat >/dev/null; perl -e 'setpgrp(0,0); sleep 3' & sleep 0.1; echo head ;;
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

    private static func writeFakeCLI(in folder: URL) throws -> URL {
        try writeScript(fakeCLI, in: folder, name: "fake-cli")
    }

    /// An executable shell script. `ConnectedToolTests` writes its stand-in tools with it.
    static func writeScript(_ body: String, in folder: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
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

    func testATaskCancelledBeforeTheRunStartsNothing() async throws {
        let marker = folder.appendingPathComponent("started")
        let command = command("marker", marker.path)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await CLIProcess.run(command, stdin: Data("x".utf8), timeout: 5, outputCap: 1 << 20)
        }
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        // A started script writes its marker within milliseconds.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the program was started")
    }

    /// The control for the test above: the same script, not cancelled, writes it.
    func testTheMarkerScriptWritesItsMarker() async {
        let marker = folder.appendingPathComponent("started")
        let outcome = await run("marker", marker.path, stdin: Data("x".utf8))
        XCTAssertEqual(outcome, .exited(status: 0, stdout: Data("x".utf8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// The check sees each line as it arrives and can end the run on it.
    func testARefusedLineStopsTheRun() async {
        let seen = Lines()
        let outcome = await CLIProcess.run(command("echo"), stdin: Data("first\nbad\nlast\n".utf8),
                                           timeout: 5, outputCap: 1 << 20) {
            seen.add($0)
            return $0 != Data("bad".utf8)
        }
        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(seen.all, [Data("first".utf8), Data("bad".utf8)])
    }

    func testACheckThatPassesEveryLineLeavesTheOutputWhole() async {
        let seen = Lines()
        let outcome = await CLIProcess.run(command("echo"), stdin: Data("one\ntwo".utf8),
                                           timeout: 5, outputCap: 1 << 20) {
            seen.add($0)
            return true
        }
        XCTAssertEqual(outcome, .exited(status: 0, stdout: Data("one\ntwo".utf8)))
        XCTAssertEqual(seen.all, [Data("one".utf8), Data("two".utf8)], "the last line has no newline")
    }

    /// The leader exits in time, and the timer fires while stdout is still held open.
    /// The exit wins: the reader drains the rest and the outcome is the program's own.
    func testAnExitBeforeTheTimeoutWinsWhileStdoutDrains() async {
        let outcome = await run("late", timeout: 0.3)
        XCTAssertEqual(outcome, .exited(status: 0, stdout: Data("head\ntail\n".utf8)))
    }

    /// The bound on that drain: something outside the group that keeps stdout open ends
    /// the read a second after the timeout.
    func testAStdoutHeldOutsideTheGroupStillTimesOut() async {
        let started = Date()
        let outcome = await run("hang", timeout: 0.3)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
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

    /// Every blocking call runs on a thread of its own, so runs never hold the task pool
    /// the app's async work waits on. Three runs per core, each a second long: a run that
    /// blocked a pool thread would make them take turns, three seconds or more.
    func testManyRunsAtOnceDoNotHoldTheTaskPool() async {
        let commands = (0..<ProcessInfo.processInfo.activeProcessorCount * 3).map {
            command("sleep", folder.appendingPathComponent("pid-\($0)").path)
        }
        let started = Date()
        await withTaskGroup(of: CLIProcess.Outcome.self) { group in
            for command in commands {
                group.addTask { await CLIProcess.run(command, stdin: Data(), timeout: 1, outputCap: 1_024) }
            }
            for await outcome in group { XCTAssertEqual(outcome, .timedOut) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "the runs took turns on the task pool")
    }

    func testAMissingProgramCouldNotStart() async {
        let missing = CLIProcess.Command(executable: folder.appendingPathComponent("missing"),
                                         arguments: [], environment: [:])
        let outcome = await CLIProcess.run(missing, stdin: Data(), timeout: 5, outputCap: 1024)
        XCTAssertEqual(outcome, .couldNotStart(errno: ENOENT))
    }
}

/// The lines a check was handed.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []

    func add(_ line: Data) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    var all: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
