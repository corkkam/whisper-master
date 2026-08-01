import Foundation

/// Bounded retry budget for rebuilding the capture graph after an audio route
/// change (`MicrophoneCaptureService.handleConfigurationChange`).
///
/// Recovering is the right answer to *a* route change — the words still matter — but
/// each rebuild can itself provoke another configuration change, and a genuinely
/// flapping route (a dock waking up, a Bluetooth device reconnecting in a loop) would
/// otherwise have us rebuilding the graph for as long as it lasts. So recovery gets a
/// budget: `limit` attempts inside `window`, after which the session is abandoned
/// honestly instead of looping.
///
/// Pure and clock-injected (`now` on every call), so the arithmetic that stops an
/// infinite loop is verified by tests rather than by unplugging speakers.
struct CaptureRecoveryBudget {
    /// Attempts allowed inside one window.
    var limit: Int = 3
    /// How long a burst of attempts is counted together. Past this, the next attempt
    /// starts a fresh burst — a route change an hour later is not part of this one.
    var window: TimeInterval = 2

    private var attempts = 0
    private var startedAt: TimeInterval?

    init(limit: Int = 3, window: TimeInterval = 2) {
        self.limit = limit
        self.window = window
    }

    /// Count an attempt and say whether it may proceed.
    mutating func allowAttempt(now: TimeInterval) -> Bool {
        if let startedAt, now - startedAt > window {
            attempts = 0
            self.startedAt = nil
        }
        if startedAt == nil { startedAt = now }
        attempts += 1
        return attempts <= limit
    }

    /// Forget everything — called when a capture starts, so a flap during the last
    /// session can't spend this one's budget.
    mutating func reset() {
        attempts = 0
        startedAt = nil
    }
}
