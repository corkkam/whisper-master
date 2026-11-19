import Darwin
import Foundation

/// Runs one command-line program to completion with hard limits. Used by the connected
/// tool tier (`ConnectedTool`, `ConnectedToolGenerator`), and **the only code that
/// spawns, kills and reaps a process for it**.
///
/// `Process` is not used: it documents no process group, and a parent cannot move a
/// child into a new group after the child has called `execve`. So `posix_spawn`:
///
/// - **The child leads its own process group**, so a kill reaches anything it starts.
/// - **It runs in an empty temporary folder** (`mkdtemp`, mode 0700, removed after the
///   run), with only the environment it is given and no file descriptor of the app's.
///   stderr goes to /dev/null: it is never read, logged or stored.
/// - **The input goes over stdin, never argv**: every process on the Mac can read argv
///   with `ps`. The write end ignores SIGPIPE (`F_SETNOSIGPIPE`), because a child that
///   exits before it reads would otherwise end the app.
/// - **A timeout, the output cap and the task's cancel all stop the whole group**:
///   SIGTERM, then SIGKILL a second later. The first reason wins.
/// - **It always reaps.** It waits for the exit without reaping (`WNOWAIT`) and kills
///   what is left of the group while the exited child still holds the group id, so a
///   kill can never reach a group that reused the id.
///
/// Every blocking call runs on a thread of its own; the caller only awaits.
enum CLIProcess {
    struct Command: Equatable, Sendable {
        var executable: URL
        /// Constants only. argv is readable by every process on the Mac.
        var arguments: [String]
        /// The child's whole environment. Nothing of the app's own is added.
        var environment: [String: String]
    }

    enum Outcome: Equatable, Sendable {
        /// The program ended by itself. One ended by a signal that did not come from
        /// here reads as 128 plus the signal number, the shell's convention.
        case exited(status: Int32, stdout: Data)
        case timedOut
        /// stdout passed the cap.
        case tooLarge
        /// The calling task was cancelled: Escape, a sign-out, or the loop's budget.
        case cancelled
        case couldNotStart(errno: Int32)
    }

    /// `run`, as a value a caller can replace in a test.
    typealias Runner = @Sendable (Command, Data, TimeInterval, Int) async -> Outcome

    static let live: Runner = { command, stdin, timeout, outputCap in
        await run(command, stdin: stdin, timeout: timeout, outputCap: outputCap)
    }

    static func run(_ command: Command, stdin: Data, timeout: TimeInterval,
                    outputCap: Int) async -> Outcome {
        let job = Job()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                job.start(command, stdin: stdin, timeout: timeout, outputCap: outputCap) {
                    continuation.resume(returning: $0)
                }
            }
        } onCancel: {
            job.stop(.cancelled)
        }
    }
}

/// One run's shared state. Locked, because the writer, the reader, the reaper, the
/// timer and the cancel handler each run on a thread of their own.
private final class Job: @unchecked Sendable {
    private let lock = NSLock()
    /// 0 until the child exists.
    private var pid: pid_t = 0
    /// Set under the lock before the child is reaped. While false, the exited child
    /// still holds its pid, so the group id is still ours to kill.
    private var reaped = false
    private var finished = false
    /// The first reason to stop; nil while the program may still end by itself.
    private var reason: CLIProcess.Outcome?
    // Each is written by one thread and read after the group is done.
    private var output = Data()
    private var exitStatus: Int32 = 0

    /// Records why (the first reason wins) and stops the group. Once the run is over,
    /// it does nothing: a timer that fires late must not rewrite the outcome.
    func stop(_ why: CLIProcess.Outcome) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if reason == nil { reason = why }
        lock.unlock()
        signalGroup()
    }

    /// A stop was asked for, or the run is over: the writer and the reader give up.
    private var quitting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reason != nil || finished
    }

    /// SIGTERM now and SIGKILL in a second, each only while the child is not reaped.
    private func signalGroup() {
        lock.lock()
        if pid > 0, !reaped { killpg(pid, SIGTERM) }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            if pid > 0, !reaped { killpg(pid, SIGKILL) }
            lock.unlock()
        }
    }

    func start(_ command: CLIProcess.Command, stdin: Data, timeout: TimeInterval,
               outputCap: Int, done: @escaping @Sendable (CLIProcess.Outcome) -> Void) {
        // A task already cancelled runs its cancel handler first: start nothing.
        lock.lock()
        if let reason {
            finished = true
            lock.unlock()
            done(reason)
            return
        }
        lock.unlock()

        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-cli-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { return finishEarly(errno, done) }
        let folder = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0 else { return finishEarly(errno, done, removing: folder) }
        guard pipe(&outPipe) == 0 else {
            inPipe.forEach { close($0) }
            return finishEarly(errno, done, removing: folder)
        }
        // No other spawn in the app may inherit these.
        for fd in inPipe + outPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)

        var child: pid_t = 0
        let failed = Self.spawn(command, stdin: inPipe[0], stdout: outPipe[1], folder: folder, pid: &child)
        close(inPipe[0])
        close(outPipe[1])
        guard failed == 0 else {
            close(inPipe[1])
            close(outPipe[0])
            return finishEarly(failed, done, removing: folder)
        }

        lock.lock()
        pid = child
        let stopAsked = reason != nil
        lock.unlock()
        // A cancel that came while the child was being made.
        if stopAsked { signalGroup() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in stop(.timedOut) }

        let group = DispatchGroup()
        group.enter()
        group.enter()
        Thread { [self] in
            write(stdin, to: inPipe[1])
            close(inPipe[1])
        }.start()
        Thread { [self] in
            read(from: outPipe[0], cap: outputCap)
            close(outPipe[0])
            group.leave()
        }.start()
        Thread { [self] in
            reap(child)
            group.leave()
        }.start()
        group.notify(queue: .global()) { [self] in
            lock.lock()
            finished = true
            let why = reason
            lock.unlock()
            try? FileManager.default.removeItem(atPath: folder)
            done(why ?? .exited(status: Self.code(exitStatus), stdout: output))
        }
    }

    private func finishEarly(_ code: Int32, _ done: (CLIProcess.Outcome) -> Void,
                             removing folder: String? = nil) {
        if let folder { try? FileManager.default.removeItem(atPath: folder) }
        lock.lock()
        finished = true
        lock.unlock()
        done(.couldNotStart(errno: code))
    }

    /// 0 and the child's pid, or the error number.
    private static func spawn(_ command: CLIProcess.Command, stdin: Int32, stdout: Int32,
                              folder: String, pid: inout pid_t) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own group (0: the child leads it), none of the app's descriptors, and
        // default signal handling with nothing blocked, whatever the app set.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, folder)

        let path = command.executable.path
        let argv = ([path] + command.arguments).map { strdup($0) } + [nil]
        let envp = command.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        return posix_spawn(&pid, path, &actions, &attributes, argv, envp)
    }

    /// All of `data`, unless the child stops reading or the run ends first. Non-blocking
    /// with a short poll, so a grandchild that holds stdin open cannot keep this thread.
    private func write(_ data: Data, to fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count, !quitting {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EAGAIN || errno == EINTR {
                    var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&ready, 1, 100)
                } else {
                    return  // EPIPE: the child closed its stdin.
                }
            }
        }
    }

    /// stdout until EOF, the cap plus one byte, or a stop. Polled, so a timeout ends the
    /// read even when a grandchild outside the group holds stdout open.
    private func read(from fd: Int32, cap: Int) {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !quitting {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, 100)
            if polled == 0 || (polled < 0 && errno == EINTR) { continue }
            let room = min(chunk.count, cap + 1 - output.count)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, room) }
            if count > 0 {
                output.append(contentsOf: chunk[0..<count])
                if output.count > cap {
                    stop(.tooLarge)
                    return
                }
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                return
            }
        }
    }

    private func reap(_ child: pid_t) {
        var info = siginfo_t()
        while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        lock.lock()
        // What the child left running in its group. This also closes a stdout that a
        // grandchild still holds, so the reader sees EOF.
        killpg(child, SIGKILL)
        reaped = true
        lock.unlock()
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1, errno == EINTR {}
        exitStatus = status
    }

    /// The exit status from a `waitpid` status word (the `WEXITSTATUS` and `WTERMSIG`
    /// macros, which Swift does not import).
    private static func code(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
