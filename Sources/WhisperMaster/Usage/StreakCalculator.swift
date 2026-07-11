import Foundation

/// Pure streak math over the set of local calendar days that had a dictation.
/// Days are `yyyy-MM-dd` strings (produced by `dayKey`) so the calculation is
/// timezone-explicit and trivially unit-testable — no `Date()`, no `UsageStore`.
enum StreakCalculator {
    /// The canonical day key: local `yyyy-MM-dd`. The one formatter the whole
    /// usage layer keys off (streaks, rollups, sync payloads).
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let f = formatter(calendar)
        return f.string(from: date)
    }

    /// Consecutive active days ending today (or yesterday — a gap of one day
    /// isn't broken until today itself lapses, so a streak stays alive all day
    /// after yesterday's session).
    static func currentStreak(activeDays: Set<String>, today: Date, calendar: Calendar = .current) -> Int {
        guard !activeDays.isEmpty else { return 0 }
        let todayKey = dayKey(for: today, calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let yesterdayKey = dayKey(for: yesterday, calendar: calendar)

        var anchor: Date
        if activeDays.contains(todayKey) {
            anchor = today
        } else if activeDays.contains(yesterdayKey) {
            anchor = yesterday
        } else {
            return 0
        }

        var streak = 0
        var cursor = anchor
        while activeDays.contains(dayKey(for: cursor, calendar: calendar)) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    /// Longest run of consecutive active days anywhere in the history.
    static func longestStreak(activeDays: Set<String>, calendar: Calendar = .current) -> Int {
        guard !activeDays.isEmpty else { return 0 }
        let f = formatter(calendar)
        var longest = 0
        for key in activeDays {
            guard let date = f.date(from: key) else { continue }
            // Only start counting from a run's first day (its predecessor is idle).
            let prevKey = dayKey(for: calendar.date(byAdding: .day, value: -1, to: date) ?? date, calendar: calendar)
            if activeDays.contains(prevKey) { continue }
            var run = 0
            var cursor = date
            while activeDays.contains(dayKey(for: cursor, calendar: calendar)) {
                run += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            longest = max(longest, run)
        }
        return longest
    }

    private static func formatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
}
