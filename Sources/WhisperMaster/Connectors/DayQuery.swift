import Foundation

/// A cheap, pure gate that answers one question of a finished transcript — *is
/// this the user asking about their day / schedule?* — without touching any model.
/// Conservative like `CommandDetector`: it only fires on a recognizable phrase, so
/// ordinary dictation is never hijacked into a query.
enum DayQueryDetector {
    /// Leading wake phrases (the dictation hotkey path). Sorted longest-first at
    /// match time so the fullest phrase wins.
    private static let wakePhrases = [
        "hey whisper what's my day", "hey whisper what is my day",
        "hey whisper what's on my calendar", "hey whisper how's my day",
        "hey whisper what's my schedule",
        "what's my day", "what is my day", "what's my day look like",
        "what does my day look like", "how's my day", "how is my day",
        "what's on my calendar", "what is on my calendar", "what's on today",
        "what do i have today", "what's my schedule", "what is my schedule",
        "what's on my schedule", "what's on my plate today",
        "what's coming up today", "what's next today", "what's happening today",
    ]

    /// True when the transcript looks like a "what's my day" question. Matches a
    /// leading wake phrase, or (looser) any phrase that mentions the user's own
    /// day/calendar/schedule as a question.
    static func matches(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !lower.isEmpty else { return false }
        for phrase in wakePhrases.sorted(by: { $0.count > $1.count }) {
            if lower == phrase || lower.hasPrefix(phrase + " ") || lower.hasPrefix(phrase + "?") {
                return true
            }
        }
        // Looser catch: a possessive "my {day,calendar,schedule,meetings}" asked
        // as a question anywhere in a short utterance.
        let mentionsMine = ["my day", "my calendar", "my schedule", "my meetings", "my agenda"]
            .contains { lower.contains($0) }
        let isQuestion = lower.hasSuffix("?")
            || lower.hasPrefix("what") || lower.hasPrefix("how") || lower.hasPrefix("do i")
            || lower.hasPrefix("when") || lower.hasPrefix("show me")
        return mentionsMine && isQuestion && lower.count < 80
    }
}

/// The result of a day query — the compact answer surfaced in the notch. Kept to
/// a headline + one detail line so it fits the notch band like the other banners.
struct DaySummary: Equatable, Sendable {
    let headline: String
    let detail: String
    /// Full event list behind the summary, for a future richer surface / logging.
    let events: [DayEvent]
    /// Connectors that were on but couldn't contribute (OAuth not configured, or
    /// calendar access not granted) — surfaced so the answer is honest about gaps.
    let unavailable: [String]

    var accessibilityText: String {
        var parts = [headline, detail]
        if !unavailable.isEmpty { parts.append("Not connected: \(unavailable.joined(separator: ", ")).") }
        return parts.joined(separator: ". ")
    }
}

/// Builds a `DaySummary` from the enabled connectors. Real calendar data comes
/// from `CalendarConnector` (EventKit); OAuth connectors that aren't configured
/// are reported in `unavailable` rather than faked.
@MainActor
enum DaySummaryService {
    static func build(store: ConnectorStore, calendar: CalendarConnector? = nil, now: Date = Date()) -> DaySummary {
        let calendar = calendar ?? .shared
        var unavailable: [String] = []

        // Calendar (the part that's genuinely live today).
        var events: [DayEvent] = []
        if store.anyCalendarEnabled {
            if calendar.isAuthorized {
                events = calendar.todaysEvents(now: now)
            } else {
                unavailable.append("Calendar (allow access)")
            }
        }

        // OAuth connectors the user turned on but that can't fetch yet.
        for kind in store.enabledOrdered where kind.auth == .oauth {
            // Outlook's calendar side flows through EventKit; only flag its mail.
            if !OAuthConnectorConfig.isConfigured(kind) {
                unavailable.append(kind.displayName)
            }
        }

        let headline = Self.headline(for: events, now: now)
        let detail = Self.detail(for: events, now: now)
        return DaySummary(headline: headline, detail: detail, events: events, unavailable: unavailable)
    }

    private static func headline(for events: [DayEvent], now: Date) -> String {
        if events.isEmpty { return "Nothing on your calendar today" }
        let count = events.count
        let upcoming = events.filter { $0.end >= now }.count
        if upcoming == 0 { return "\(count) event\(count == 1 ? "" : "s") today, all done" }
        return "\(count) event\(count == 1 ? "" : "s") today"
    }

    private static func detail(for events: [DayEvent], now: Date) -> String {
        guard !events.isEmpty else { return "You're clear. Enjoy it." }
        // The next event that hasn't ended yet, else the first of the day.
        let next = events.first { $0.end >= now } ?? events[0]
        if next.isAllDay {
            return "Next: \(next.title) · all day"
        }
        return "Next: \(next.title) · \(timeString(next.start))"
    }

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
