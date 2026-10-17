import Foundation

/// Counts MLX work in flight, so a quit can wait for it instead of tearing MLX
/// down underneath it.
///
/// MLX keeps process-wide C++ state (its Metal scheduler, compile cache and
/// thread pool) that `exit()` destroys as static destructors run. A quit that
/// lands while a generation is still running on a cooperative thread destroys
/// that state mid-generation, and the process crashes on the way out: Metal
/// asserts ("Completed handler provided after commit call") or MLX reads freed
/// memory in its compile cache. Both were captured on 2026-10-18 from Cmd+Q during
/// a Model Lab run. The same path is open in the shipped app: a quit, or Sparkle's
/// quit-to-install, during a dictation's cleanup or an assistant turn.
///
/// How it is used: `MlxCleanupService` brackets every model load and every
/// generation with `enter` / `leave` and does no MLX work when `enter` refuses,
/// and its token loops stop at the next token once `isQuitting` is set.
/// `AppDelegate.applicationShouldTerminate` calls `beginQuit()` and holds the
/// quit until `drain` returns.
final class MlxWorkGate: @unchecked Sendable {
    static let shared = MlxWorkGate()

    private let lock = NSLock()
    private var running = 0
    private var quitting = false

    /// How long a quit waits for running work. A generation stops within one
    /// token of `beginQuit`, so this only matters for a model load, which cannot
    /// be interrupted; past it the app quits anyway rather than hang.
    static let quitTimeoutSeconds: TimeInterval = 3

    var isQuitting: Bool { lock.withLock { quitting } }
    var inFlight: Int { lock.withLock { running } }

    /// Count one piece of work in, or refuse it once a quit has begun. The check
    /// and the count share the lock, so after `beginQuit` the count can only
    /// fall: without the refusal, a bench's next case (or a dictation finishing
    /// during the hold) started a fresh generation after `drain` had already
    /// seen zero, and the crash came back on half of all quits.
    @discardableResult
    func enter() -> Bool {
        lock.withLock {
            guard !quitting else { return false }
            running += 1
            return true
        }
    }

    func leave() { lock.withLock { running -= 1 } }

    enum Refused: Error { case quitting }

    func beginQuit() { lock.withLock { quitting = true } }

    /// True once nothing is running, false if `timeout` passed first.
    func drain(timeout: TimeInterval, poll: TimeInterval = 0.02) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while inFlight > 0 {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        return true
    }
}
