import Foundation

/// The free time on one day, for `find_free_slots`. Pure, so the edge cases (overlaps,
/// back-to-back events, an event across midnight) are pinned without a calendar.
enum FreeSlotFinder {
    /// The most slots one result lists.
    static let limit = 8

    /// The hours searched when the user names none: 09:00 to 18:00.
    static let defaultHours = (start: (9, 0), end: (18, 0))

    /// The search window on `day`. `between` is the user's words ("9am to 6pm",
    /// "10 to 4"); nil uses `defaultHours`. Nil when `between` is not two clock times
    /// in order, so the call fails rather than search hours nobody asked for.
    static func window(on day: Date,
                       between: String?,
                       calendar: Calendar = .current) -> DateInterval? {
        var hours = defaultHours
        if let between, !between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sides = between.lowercased()
                .replacingOccurrences(of: #"^\s*(between|from)\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+(to|until|till|and)\s+|\s*[-\x{2013}\x{2014}]\s*"#,
                                      with: "\u{0}", options: .regularExpression)
                .components(separatedBy: "\u{0}")
            // "at " makes a bare hour a clock time, the same reading as "at 5".
            guard sides.count == 2,
                  let start = RelativeTimeParser.parseClock("at " + sides[0]),
                  let end = RelativeTimeParser.parseClock("at " + sides[1])
            else { return nil }
            hours = (start, end)
        }
        guard let start = calendar.date(bySettingHour: hours.start.0, minute: hours.start.1, second: 0, of: day),
              let end = calendar.date(bySettingHour: hours.end.0, minute: hours.end.1, second: 0, of: day),
              start < end
        else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The free stretches in `window` that last at least `minutes`, earliest first,
    /// at most `limit` of them. Each is the whole gap between two events, not a cut
    /// of `minutes`, so the model can offer any time inside it.
    ///
    /// - All-day events do not count as busy: a birthday or a holiday on the
    ///   calendar does not fill the day. The caller says so in the result.
    /// - An event that starts before the window or ends after it (one across
    ///   midnight too) blocks only the part inside the window.
    /// - `notBefore` (now, for today) moves the start forward, rounded up to the next
    ///   quarter hour, so a slot never starts in the past or at 2:07.
    static func slots(in window: DateInterval,
                      events: [DayEvent],
                      minutes: Int,
                      notBefore: Date? = nil,
                      limit: Int = limit) -> [DateInterval] {
        var cursor = window.start
        if let notBefore {
            let quarter: TimeInterval = 15 * 60
            let rounded = Date(timeIntervalSinceReferenceDate:
                (notBefore.timeIntervalSinceReferenceDate / quarter).rounded(.up) * quarter)
            cursor = max(cursor, rounded)
        }
        let needed = TimeInterval(max(minutes, 1) * 60)
        let busy = events
            .filter { !$0.isAllDay && $0.end > window.start && $0.start < window.end }
            .sorted { $0.start < $1.start }
        var free: [DateInterval] = []
        for event in busy {
            if event.start.timeIntervalSince(cursor) >= needed {
                free.append(DateInterval(start: cursor, end: event.start))
            }
            cursor = max(cursor, event.end)
        }
        if window.end.timeIntervalSince(cursor) >= needed {
            free.append(DateInterval(start: cursor, end: window.end))
        }
        return Array(free.prefix(limit))
    }
}
