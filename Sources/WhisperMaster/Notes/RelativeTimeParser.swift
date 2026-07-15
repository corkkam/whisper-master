import Foundation

/// Turns an explicit spoken time expression into a concrete due `Date`. Pure and
/// deterministic — `now` and the calendar are injected so tests don't depend on
/// the wall clock. **Conservative on purpose:** it only resolves clearly-stated
/// times ("at 5pm", "tomorrow morning", "in 2 hours", "tonight", "next monday").
/// Anything it can't confidently pin returns `nil`, which is the signal to *ask*
/// the user — matching the product rule that a reminder without a stated time
/// prompts for one rather than guessing.
enum RelativeTimeParser {
    /// Part-of-day → hour, used when a day is named but no clock time is.
    private static let morning = 9
    private static let afternoon = 14
    private static let evening = 18
    private static let night = 20

    static func parse(_ phrase: String, now: Date, calendar: Calendar = .current) -> Date? {
        let lower = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }
        let tokens = lower.split { !$0.isLetter && !$0.isNumber && $0 != ":" }.map(String.init)

        // "in 5 minutes", "in an hour", "in 2 days"
        if let d = parseRelativeOffset(tokens, now: now, calendar: calendar) { return d }

        // "tonight", "this evening/afternoon/morning"
        if let d = parseTonightOrThis(lower, now: now, calendar: calendar) { return d }

        // "tomorrow" (+ optional "morning" / "at 5pm")
        if lower.contains("tomorrow") {
            return parseTomorrow(lower, now: now, calendar: calendar)
        }

        // "monday", "next friday", "on tuesday" (+ optional "at 9")
        if let d = parseWeekday(lower, now: now, calendar: calendar) { return d }

        // A bare clock time — "at 5pm", "at 9:30", "noon"
        if let (h, m) = parseClock(lower) {
            return atTimeTodayOrTomorrow(hour: h, minute: m, now: now, calendar: calendar)
        }
        return nil
    }

    // MARK: - "in N units"

    private static func parseRelativeOffset(_ tokens: [String], now: Date, calendar: Calendar) -> Date? {
        guard let inIdx = tokens.firstIndex(of: "in"), inIdx + 2 <= tokens.count - 1 else { return nil }
        guard let amount = numberValue(tokens[inIdx + 1]) else { return nil }
        let component: Calendar.Component
        switch tokens[inIdx + 2] {
        case "minute", "minutes", "min", "mins": component = .minute
        case "hour", "hours", "hr", "hrs": component = .hour
        case "day", "days": component = .day
        case "week", "weeks": component = .weekOfYear
        default: return nil
        }
        return calendar.date(byAdding: component, value: amount, to: now)
    }

    // MARK: - tonight / this <part>

    private static func parseTonightOrThis(_ lower: String, now: Date, calendar: Calendar) -> Date? {
        if lower.contains("tonight") {
            return futureTimeToday(hour: night, minute: 0, now: now, calendar: calendar)
        }
        if lower.contains("this evening") {
            return futureTimeToday(hour: evening, minute: 0, now: now, calendar: calendar)
        }
        if lower.contains("this afternoon") {
            return futureTimeToday(hour: afternoon, minute: 0, now: now, calendar: calendar)
        }
        if lower.contains("this morning") {
            return futureTimeToday(hour: morning, minute: 0, now: now, calendar: calendar)
        }
        return nil
    }

    /// Today at the given time, but only if it's still ahead of `now` — else `nil`
    /// (a "this afternoon" that has already passed is ambiguous, so we ask).
    private static func futureTimeToday(hour: Int, minute: Int, now: Date, calendar: Calendar) -> Date? {
        guard let t = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        return t > now ? t : nil
    }

    // MARK: - tomorrow

    private static func parseTomorrow(_ lower: String, now: Date, calendar: Calendar) -> Date? {
        guard let base = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        let (h, m) = parseClock(lower) ?? (partOfDayHour(lower) ?? morning, 0)
        return calendar.date(bySettingHour: h, minute: m, second: 0, of: base)
    }

    // MARK: - weekdays

    private static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    private static func parseWeekday(_ lower: String, now: Date, calendar: Calendar) -> Date? {
        guard let target = weekdays.first(where: { lower.contains($0.key) })?.value else { return nil }
        let (h, m) = parseClock(lower) ?? (partOfDayHour(lower) ?? morning, 0)
        var comps = DateComponents()
        comps.weekday = target
        comps.hour = h
        comps.minute = m
        comps.second = 0
        return calendar.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
    }

    // MARK: - clock times

    private static func partOfDayHour(_ lower: String) -> Int? {
        if lower.contains("morning") { return morning }
        if lower.contains("afternoon") { return afternoon }
        if lower.contains("evening") { return evening }
        if lower.contains("night") { return night }
        return nil
    }

    /// Extract an explicit clock time: "noon", "midnight", "at 5", "at 9:30",
    /// "5pm", "9:30 am". Returns `(hour24, minute)` or `nil`.
    static func parseClock(_ lower: String) -> (Int, Int)? {
        if lower.contains("noon") { return (12, 0) }
        if lower.contains("midnight") { return (0, 0) }

        // "at H(:MM)(am/pm)" — the "at" makes even a bare hour clearly a time.
        if let m = firstMatch(#"at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#, in: lower) {
            return normalizeClock(hour: m.int(1), minute: m.int(2), meridiem: m.str(3), hadAt: true)
        }
        // Bare "H:MM(am/pm)" — the colon marks it as a time, not a count.
        if let m = firstMatch(#"(\d{1,2}):(\d{2})\s*(am|pm)?"#, in: lower) {
            return normalizeClock(hour: m.int(1), minute: m.int(2), meridiem: m.str(3), hadAt: false)
        }
        // Bare "H am/pm" — the meridiem marks it as a time.
        if let m = firstMatch(#"(\d{1,2})\s*(am|pm)"#, in: lower) {
            return normalizeClock(hour: m.int(1), minute: nil, meridiem: m.str(2), hadAt: false)
        }
        return nil
    }

    private static func normalizeClock(hour: Int?, minute: Int?, meridiem: String?, hadAt: Bool) -> (Int, Int)? {
        guard let hourVal = hour, hourVal >= 0, hourVal <= 23 else { return nil }
        var h = hourVal
        let m = minute ?? 0
        guard m >= 0, m <= 59 else { return nil }
        switch meridiem {
        case "am": if h == 12 { h = 0 }
        case "pm": if h != 12 { h += 12 }
        default:
            // No am/pm stated: an "at 1..7" almost always means afternoon/evening.
            if hadAt, h >= 1, h <= 7 { h += 12 }
        }
        guard h >= 0, h <= 23 else { return nil }
        return (h, m)
    }

    // MARK: - today-or-tomorrow

    private static func atTimeTodayOrTomorrow(hour: Int, minute: Int, now: Date, calendar: Calendar) -> Date? {
        guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    // MARK: - number words

    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
        "sixty": 60, "half": 30, "couple": 2, "few": 3,
    ]

    private static func numberValue(_ token: String) -> Int? {
        if let n = Int(token) { return n }
        return numberWords[token]
    }

    // MARK: - regex helper

    private struct RegexMatch {
        let groups: [String?]
        func str(_ i: Int) -> String? { (i < groups.count ? groups[i] : nil)?.lowercased() }
        func int(_ i: Int) -> Int? { (i < groups.count ? groups[i] : nil).flatMap { Int($0) } }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> RegexMatch? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, range: range) else { return nil }
        var groups: [String?] = []
        for i in 0 ..< match.numberOfRanges {
            if let r = Range(match.range(at: i), in: text) {
                groups.append(String(text[r]))
            } else {
                groups.append(nil)
            }
        }
        return RegexMatch(groups: groups)
    }
}

/// The fixed quick-time choices offered in the notch "when?" prompt. Pure so the
/// labels/dates are unit-testable against a fixed `now`.
enum ReminderQuickTimes {
    struct Option: Identifiable, Equatable {
        let id: String
        let label: String
        let date: Date
    }

    static func options(now: Date, calendar: Calendar = .current) -> [Option] {
        var opts: [Option] = []
        if let d = calendar.date(byAdding: .hour, value: 1, to: now) {
            opts.append(.init(id: "hour", label: "In 1 hour", date: d))
        }
        if let d = nextOccurrence(hour: 18, minute: 0, now: now, calendar: calendar) {
            let label = calendar.isDate(d, inSameDayAs: now) ? "This evening" : "Tomorrow evening"
            opts.append(.init(id: "evening", label: label, date: d))
        }
        if let base = calendar.date(byAdding: .day, value: 1, to: now),
           let d = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: base) {
            opts.append(.init(id: "tomorrow", label: "Tomorrow 9 AM", date: d))
        }
        return opts
    }

    private static func nextOccurrence(hour: Int, minute: Int, now: Date, calendar: Calendar) -> Date? {
        guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
}
