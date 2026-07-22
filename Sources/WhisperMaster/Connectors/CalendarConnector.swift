import EventKit
import Foundation

/// A single calendar event, flattened to the value type the day summary needs
/// (so the UI/summary layer never touches EventKit types).
struct DayEvent: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// The calendar's name ("Work", "Personal") and its account source title
    /// ("Google", "iCloud", "Exchange") — lets the summary say where an event came
    /// from, which is how a Google/Outlook calendar shows up honestly.
    let calendarTitle: String
    let sourceTitle: String

    var isUpcoming: Bool { end >= Date() }
}

/// Reads today's events from **all** calendars macOS knows about via EventKit.
/// Because the macOS Calendar app aggregates iCloud, Google, Exchange/Outlook and
/// `.ics` subscriptions, this is real, live data for the `appleCalendar`,
/// `googleCalendar` and `outlook` (calendar) connectors — no OAuth of our own.
@MainActor
final class CalendarConnector {
    static let shared = CalendarConnector()

    private let store = EKEventStore()

    /// True when the app has full read access to events.
    var isAuthorized: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .authorized: return true      // pre-macOS-14 value, still reported
        default: return false
        }
    }

    /// Whether we've never asked (so the UI can offer "Allow calendar access"
    /// rather than a dead "denied — open Settings" state).
    var isUndetermined: Bool {
        EKEventStore.authorizationStatus(for: .event) == .notDetermined
    }

    /// Prompt for calendar access (or return the existing grant). Requires the
    /// `NSCalendarsFullAccessUsageDescription` string in Info.plist or macOS
    /// hard-crashes the prompt.
    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    /// Today's events (from now-relative midnight to midnight), sorted by start.
    /// Empty when unauthorized — callers gate on `isAuthorized`.
    func todaysEvents(now: Date = Date()) -> [DayEvent] {
        guard isAuthorized else { return [] }
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }

        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map {
                DayEvent(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    title: ($0.title ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines),
                    start: $0.startDate,
                    end: $0.endDate,
                    isAllDay: $0.isAllDay,
                    calendarTitle: $0.calendar?.title ?? "",
                    sourceTitle: $0.calendar?.source?.title ?? "")
            }
    }
}
