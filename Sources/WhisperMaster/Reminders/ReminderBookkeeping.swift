import Foundation

/// Persisted bookkeeping that the reminder cadence is computed from.
///
/// A plain value type — `ReminderPolicy` reads it to decide whether to nudge,
/// the scheduler mutates it as use/nudges happen. Persisted under its own
/// UserDefaults key so backoff survives relaunch.
struct ReminderBookkeeping: Codable, Equatable {
    /// First time we ever saw the user — the cadence reference before any use,
    /// so a fresh install isn't nudged within the first idle gap.
    var firstSeenAt: Date?
    /// Last completed dictation. Resets the backoff to the friendly baseline.
    var lastUsedAt: Date?
    /// When the most recent nudge was shown.
    var lastNudgeAt: Date?
    /// Nudges shown since the last completed dictation — drives the backoff.
    var nudgesSinceLastUse: Int = 0
    /// Start of the current rolling daily-cap window (first nudge of the window).
    var dayWindowStart: Date?
    /// Nudges shown within the current daily-cap window.
    var nudgesInDayWindow: Int = 0
    /// Index of the last copy line shown, so we can rotate past it.
    var lastLineIndex: Int?

    /// The instant the cadence measures idle time from: the most recent of last
    /// use, last nudge, or first-seen. `nil` only before `firstSeenAt` is set.
    var cadenceReference: Date? {
        [lastUsedAt, lastNudgeAt, firstSeenAt].compactMap { $0 }.max()
    }

    /// Record a completed dictation — back to the friendly baseline.
    mutating func noteUsed(at now: Date) {
        lastUsedAt = now
        nudgesSinceLastUse = 0
    }

    /// Record that a nudge was just shown, advancing backoff + daily-cap state.
    mutating func noteNudged(at now: Date, lineIndex: Int, dailyWindow: TimeInterval) {
        lastNudgeAt = now
        nudgesSinceLastUse += 1
        lastLineIndex = lineIndex

        if let start = dayWindowStart, now.timeIntervalSince(start) < dailyWindow {
            nudgesInDayWindow += 1
        } else {
            dayWindowStart = now
            nudgesInDayWindow = 1
        }
    }
}

// MARK: - Persistence

extension ReminderBookkeeping {
    static let defaultsKey = "WhisperMaster.reminders.v1"

    static func load() -> ReminderBookkeeping {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return ReminderBookkeeping()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ReminderBookkeeping.self, from: data)) ?? ReminderBookkeeping()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
