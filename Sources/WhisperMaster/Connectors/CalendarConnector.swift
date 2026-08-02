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
    /// The **connector instance** this event was read through, e.g. "Work".
    ///
    /// Merged reads fan out across every enabled calendar instance, so an answer has
    /// to be able to say *which* named connector an event came from — that's the
    /// whole point of naming them. Empty when the read wasn't instance-scoped.
    let instanceLabel: String

    init(id: String,
         title: String,
         start: Date,
         end: Date,
         isAllDay: Bool,
         calendarTitle: String,
         sourceTitle: String,
         instanceLabel: String = "") {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.sourceTitle = sourceTitle
        self.instanceLabel = instanceLabel
    }

    var isUpcoming: Bool { end >= Date() }

    /// "Work · Google" — the provenance line under an event title. Prefers the
    /// instance label the user chose over the raw calendar name.
    var provenance: String {
        let parts = [instanceLabel.isEmpty ? calendarTitle : instanceLabel, sourceTitle]
            .filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }
}

/// One selectable calendar in the add/edit sheet, grouped by the account it comes
/// from. `identifier` is what an instance's config stores.
struct CalendarChoice: Identifiable, Hashable, Sendable {
    let identifier: String
    let title: String
    let sourceTitle: String
    /// The EventKit source type, used to pre-filter the picker by connector kind
    /// (Google → CalDAV, Outlook → Exchange, iCal → local/iCloud/subscribed).
    let sourceType: CalendarSourceType

    var id: String { identifier }
}

/// The EventKit source families we care about, mapped from `EKSourceType`.
enum CalendarSourceType: String, Sendable {
    case local, iCloud, exchange, calDAV, subscribed, birthdays, other

    init(_ type: EKSourceType) {
        switch type {
        case .local: self = .local
        case .mobileMe: self = .iCloud
        case .exchange: self = .exchange
        case .calDAV: self = .calDAV
        case .subscribed: self = .subscribed
        case .birthdays: self = .birthdays
        @unknown default: self = .other
        }
    }
}

/// Reads events from the calendars macOS knows about via EventKit.
///
/// Because the macOS Calendar app aggregates iCloud, Google, Exchange/Outlook and
/// `.ics` subscriptions, this is real, live data for every calendar connector — no
/// OAuth of our own.
///
/// **`calendarIdentifiers` is the fix for the original bug.** This used to pass
/// `calendars: nil` to the predicate, i.e. *every* calendar on the Mac, which made
/// the "Google Calendar", "Outlook" and "iCal" connectors return byte-identical
/// results — three tiles over one undifferentiated query. Reads are now scoped to the
/// calendars the instance is actually bound to. An empty list still means "every
/// calendar", which is what the legacy migration produces so an upgrade doesn't
/// silently narrow anyone's day summary.
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

    // MARK: - Calendar discovery (the add/edit sheet's picker)

    /// Every readable calendar on this Mac, sorted by account then name.
    func availableCalendars() -> [CalendarChoice] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event)
            .map {
                CalendarChoice(
                    identifier: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source?.title ?? "",
                    sourceType: CalendarSourceType($0.source?.sourceType ?? .local))
            }
            .sorted {
                $0.sourceTitle == $1.sourceTitle ? $0.title < $1.title : $0.sourceTitle < $1.sourceTitle
            }
    }

    /// The calendars a given connector kind should offer, so "Google Calendar" isn't
    /// asking you to pick your iCloud birthdays. Falls back to everything when the
    /// kind-appropriate set is empty, rather than showing an empty picker the user
    /// can't get past.
    func availableCalendars(for kind: ConnectorKind) -> [CalendarChoice] {
        let all = availableCalendars()
        let wanted: Set<CalendarSourceType>
        switch kind {
        case .googleCalendar: wanted = [.calDAV]
        case .outlook: wanted = [.exchange]
        case .appleCalendar: wanted = [.local, .iCloud, .subscribed, .birthdays]
        default: return all
        }
        let filtered = all.filter { wanted.contains($0.sourceType) }
        return filtered.isEmpty ? all : filtered
    }

    /// Whether every one of these identifiers still resolves. `calendarIdentifier` is
    /// **not** stable across an account being removed and re-added, so a bound
    /// calendar going missing is an expected state (`.calendarMissing`) with a
    /// re-pick repair — not corruption, and never a silent empty result.
    func calendarsExist(_ identifiers: [String]) -> Bool {
        guard !identifiers.isEmpty else { return true }
        let known = Set(store.calendars(for: .event).map(\.calendarIdentifier))
        return identifiers.allSatisfy(known.contains)
    }

    /// The account title behind a set of calendars — an instance's `identity`.
    func sourceTitle(forCalendars identifiers: [String]) -> String {
        guard !identifiers.isEmpty else { return "All calendars on this Mac" }
        let titles = store.calendars(for: .event)
            .filter { identifiers.contains($0.calendarIdentifier) }
            .compactMap { $0.source?.title }
        return Set(titles).sorted().joined(separator: ", ")
    }

    // MARK: - Reads

    /// Today's events (from now-relative midnight to midnight), sorted by start.
    ///
    /// - Parameter calendarIdentifiers: the calendars to read. **Empty means every
    ///   calendar** (the legacy/unscoped behaviour). Identifiers that no longer
    ///   resolve are ignored here; callers detect that case with `calendarsExist`
    ///   and surface `.calendarMissing` rather than reporting an empty day.
    /// Empty when unauthorized — callers gate on `isAuthorized`.
    func todaysEvents(calendarIdentifiers: [String] = [],
                      instanceLabel: String = "",
                      now: Date = Date()) -> [DayEvent] {
        guard isAuthorized else { return [] }
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }

        // nil = every calendar; a non-empty selection scopes the query, which is the
        // difference between a connector that means something and a decorative toggle.
        let scope: [EKCalendar]?
        if calendarIdentifiers.isEmpty {
            scope = nil
        } else {
            let wanted = Set(calendarIdentifiers)
            let matched = store.calendars(for: .event).filter { wanted.contains($0.calendarIdentifier) }
            // All bound calendars vanished — return nothing rather than silently
            // widening back to every calendar, which would resurrect the old bug.
            if matched.isEmpty { return [] }
            scope = matched
        }

        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: scope)
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
                    sourceTitle: $0.calendar?.source?.title ?? "",
                    instanceLabel: instanceLabel)
            }
    }

    // MARK: - Writes

    /// Create an event on one of this Mac's calendars.
    ///
    /// The grant we already ask for is `requestFullAccessToEvents`, which covers
    /// writing — so this needs no new permission, no OAuth and no network. That is
    /// what makes it the right home for "put it in my calendar": the same EventKit
    /// route that reads Google, Exchange and iCloud calendars can write back to them,
    /// where the API-backed Google provider only ever covered accounts the user
    /// separately signed in to.
    ///
    /// - Parameter calendarIdentifiers: the instance's bound calendars. The **first
    ///   writable** one is used; an empty list (the "every calendar" binding) falls
    ///   back to the system default. A read-only calendar — a subscribed `.ics`, a
    ///   birthdays calendar — is skipped rather than attempted, because EventKit's
    ///   error for it is opaque.
    func createEvent(title: String,
                     start: Date,
                     end: Date,
                     calendarIdentifiers: [String]) throws -> String {
        guard isAuthorized else { throw CalendarWriteError.notAuthorized }
        guard let calendar = writableCalendar(among: calendarIdentifiers) else {
            throw CalendarWriteError.noWritableCalendar
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
        return calendar.title
    }

    /// The calendar a write lands on: the first bound one that allows modification,
    /// else the store's default, else any writable calendar.
    private func writableCalendar(among identifiers: [String]) -> EKCalendar? {
        let all = store.calendars(for: .event)
        if !identifiers.isEmpty {
            let wanted = Set(identifiers)
            if let bound = all.first(where: { wanted.contains($0.calendarIdentifier) && $0.allowsContentModifications }) {
                return bound
            }
            // Every bound calendar is read-only. Widening to some other calendar here
            // would file the event somewhere the user never named, so refuse instead.
            if all.contains(where: { wanted.contains($0.calendarIdentifier) }) { return nil }
        }
        if let fallback = store.defaultCalendarForNewEvents, fallback.allowsContentModifications {
            return fallback
        }
        return all.first { $0.allowsContentModifications }
    }
}

/// Why a calendar write couldn't be attempted. Distinct cases because the repairs
/// differ: one is a permission prompt, the other is picking different calendars.
enum CalendarWriteError: Error {
    case notAuthorized
    case noWritableCalendar

    var message: String {
        switch self {
        case .notAuthorized:
            return "Calendar access isn't granted yet."
        case .noWritableCalendar:
            return "That connection's calendars are read-only, so nothing can be added to them."
        }
    }
}
