import Foundation

/// When the next sync request may go out. Shared by `UsageSyncClient` and
/// `NotesSyncClient`, which the 0.5 s `AppDelegate` tick calls freely.
///
/// A failure doubles the wait, up to `cap`; a success goes back to `base`. Before this,
/// a backend that kept failing (offline, an expired token, a deployment that was down)
/// was sent a notes pull after every failed one, about twice a second, and a push
/// every 20 s, for as long as the app ran. That is thousands of requests a day from one
/// Mac to an app that is local-first.
struct SyncBackoff {
    let base: TimeInterval
    let cap: TimeInterval
    private(set) var failures = 0
    private(set) var notBefore: Date?

    init(base: TimeInterval = 20, cap: TimeInterval = 30 * 60) {
        self.base = base
        self.cap = cap
    }

    func allows(at now: Date = Date()) -> Bool {
        notBefore.map { now >= $0 } ?? true
    }

    /// A request that worked, or one that sent nothing: wait `base` before the next.
    mutating func succeeded(at now: Date = Date()) {
        failures = 0
        notBefore = now.addingTimeInterval(base)
    }

    /// Another account signed in: the failures were the previous account's.
    mutating func reset() {
        failures = 0
        notBefore = nil
    }

    mutating func failed(at now: Date = Date()) {
        failures += 1
        let wait = min(cap, base * pow(2, Double(min(failures - 1, 16))))
        notBefore = now.addingTimeInterval(wait)
    }
}
