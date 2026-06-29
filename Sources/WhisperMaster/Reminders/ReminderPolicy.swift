import Foundation

/// The brain of gentle reminders: a pure, deterministic decision about whether
/// to nudge *now*. It never reads the clock itself — callers pass `now` — so it
/// is fully testable and all timing lives here as named constants.
///
/// Cadence: a first nudge fires once the idle gap since the last use/nudge
/// exceeds the baseline (`backoffGaps[0]`). Each nudge that goes unanswered
/// stretches the required gap along `backoffGaps`; a completed dictation resets
/// `nudgesSinceLastUse` to zero, dropping straight back to the friendly
/// baseline. A rolling daily cap bounds how many can ever fire in a day.
struct ReminderPolicy {
    /// Required idle gap by number of unanswered nudges: 3h, then 6h, then 12h
    /// (the last value holds). Index 0 is the baseline first-nudge gap.
    let backoffGaps: [TimeInterval]
    /// Most nudges allowed within any `dailyWindow`.
    let maxNudgesPerDay: Int
    /// Length of the rolling window the daily cap is measured over.
    let dailyWindow: TimeInterval
    /// How long a reminder stays dropped down before retracting.
    let displayDuration: TimeInterval

    init(
        backoffGaps: [TimeInterval] = [3 * 3600, 6 * 3600, 12 * 3600],
        maxNudgesPerDay: Int = 3,
        dailyWindow: TimeInterval = 24 * 3600,
        displayDuration: TimeInterval = 5
    ) {
        self.backoffGaps = backoffGaps.isEmpty ? [3 * 3600] : backoffGaps
        self.maxNudgesPerDay = maxNudgesPerDay
        self.dailyWindow = dailyWindow
        self.displayDuration = displayDuration
    }

    /// Whether a nudge should fire at `now`, given the current bookkeeping.
    func shouldNudge(now: Date, state: ReminderBookkeeping) -> Bool {
        guard let reference = state.cadenceReference else { return false }

        // Rolling daily cap.
        if let windowStart = state.dayWindowStart,
           now.timeIntervalSince(windowStart) < dailyWindow,
           state.nudgesInDayWindow >= maxNudgesPerDay {
            return false
        }

        let index = min(state.nudgesSinceLastUse, backoffGaps.count - 1)
        let requiredGap = backoffGaps[index]
        return now.timeIntervalSince(reference) >= requiredGap
    }
}
