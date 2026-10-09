import Foundation

/// Today's real, on-device day at a glance: the calendar agenda plus a
/// derived headline. No weather, unread-email, or AI briefing — there's no
/// backend for those, so Today only shows what's genuinely known.
struct DaySummary: Equatable {
    var events: [CalendarEvent]
    var calendarAccessGranted: Bool

    /// The next event that hasn't ended yet, for the "what's next" affordance.
    func nextEvent(now: Date = Date()) -> CalendarEvent? {
        events.first { $0.end > now && !$0.isAllDay } ?? events.first { $0.end > now }
    }
}

/// Builds `DaySummary` from the real calendar connector. Thin by design — the
/// data source is EventKit; this just packages it for the Today screen.
@MainActor
final class DaySummaryService {
    private let calendar: CalendarConnector

    init(calendar: CalendarConnector) {
        self.calendar = calendar
    }

    func build(now: Date = Date()) -> DaySummary {
        calendar.refreshAuthorization()
        return DaySummary(
            events: calendar.todaysEvents(now: now),
            calendarAccessGranted: calendar.hasAccess
        )
    }
}
