import Foundation

/// The provider behind all three calendar kinds (`appleCalendar`, `googleCalendar`,
/// `outlook`). One implementation, because macOS Calendar already aggregates those
/// accounts — what differs per kind is only which `EKSource` family the picker
/// offers, and that lives in `CalendarConnector.availableCalendars(for:)`.
///
/// The instance's `config` carries the bound calendar identifiers, so two instances of
/// the same kind read genuinely different calendars. That's what makes "Google
/// Calendar Personal" and "Google Calendar Work" distinct connections rather than two
/// names for one query.
@MainActor
struct EventKitCalendarProvider: EventReadingProvider {
    static let kind: ConnectorKind = .googleCalendar   // representative; serves all three

    private var calendar: CalendarConnector { .shared }

    /// System-backed: there is no credential to check. "Valid" means macOS has
    /// granted calendar access and the bound calendars still resolve — the two things
    /// that can actually stop this instance reading.
    func validate(_ credential: ConnectorCredential,
                  config: ConnectorConfig) async -> ValidationResult {
        guard calendar.isAuthorized else {
            return .invalid("Calendar access isn't granted yet.")
        }
        let identifiers = config.calendarIdentifiers ?? []
        guard calendar.calendarsExist(identifiers) else {
            return .invalid("Those calendars are no longer on this Mac.")
        }
        return .valid(identity: calendar.sourceTitle(forCalendars: identifiers))
    }

    /// Today's events from just this instance's calendars, each tagged with the
    /// instance label so a merged answer can name where it came from.
    ///
    /// Distinguishes "nothing scheduled" from "we lost the calendars" — the whole
    /// reason `ConnectorError.calendarMissing` exists. `calendarIdentifier` is not
    /// stable across an account being removed and re-added, so this is a state a
    /// long-lived instance genuinely reaches.
    func todaysEvents(for instance: ConnectorInstance, now: Date) -> ProviderReadOutcome<[DayEvent]> {
        guard calendar.isAuthorized else {
            return ProviderReadOutcome([], error: .needsCalendarAccess)
        }
        let identifiers = instance.config.calendarIdentifiers ?? []
        guard calendar.calendarsExist(identifiers) else {
            return ProviderReadOutcome([], error: .calendarMissing)
        }
        let events = calendar.todaysEvents(
            calendarIdentifiers: identifiers,
            instanceLabel: instance.displayLabel,
            now: now)
        return ProviderReadOutcome(events)
    }
}
