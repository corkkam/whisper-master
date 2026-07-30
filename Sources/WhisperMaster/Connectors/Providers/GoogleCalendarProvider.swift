import Foundation

/// Google Calendar over the REST API, authenticated by the PKCE grant.
///
/// This is a *different provider from `EventKitCalendarProvider`* for the same
/// `googleCalendar` kind, and both can be live at once — one instance reading the
/// calendars macOS already syncs, another reading the API directly. Which one an
/// instance uses is decided by its config: a `.calendars` config is EventKit-backed, a
/// `.googleAPI` config is this. That's why config is typed.
///
/// Worth it over EventKit because the API sees calendars macOS Calendar isn't
/// subscribed to, returns richer event data, and is the only path to *writing* events
/// later.
@MainActor
struct GoogleCalendarProvider: EventReadingProvider {
    static let kind: ConnectorKind = .googleCalendar

    private static let base = "https://www.googleapis.com/calendar/v3"

    /// Confirms the grant by asking who it belongs to. The returned email is the
    /// instance identity and prefills the label.
    func validate(_ credential: ConnectorCredential,
                  config: ConnectorConfig) async -> ValidationResult {
        guard let token = credential.accessToken else {
            return .invalid("No access token on this connection.")
        }
        do {
            let json = try await ConnectorHTTP.getJSON(
                URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!, token: token)
            guard let email = json["email"] as? String, !email.isEmpty else {
                return .invalid("Google didn't return an account email.")
            }
            return .valid(identity: email)
        } catch ConnectorHTTP.Failure.unauthorized {
            return .invalid("Google rejected the token.")
        } catch {
            return .invalid("Couldn't reach Google: \(error)")
        }
    }

    /// Today's events from the calendars this instance is bound to (or `primary`).
    ///
    /// `async` unlike the EventKit provider, so `DaySummaryService` awaits it — the
    /// price of real data over a network rather than a local store.
    func todaysEventsAsync(for instance: ConnectorInstance, now: Date) async -> ProviderReadOutcome<[DayEvent]> {
        let resolved: CredentialStrategy.Resolved
        do {
            resolved = try await CredentialStrategy.resolve(for: instance)
        } catch {
            return ProviderReadOutcome([], error: CredentialStrategy.connectorError(for: error))
        }
        // A refresh may have produced new tokens — persist once, here, rather than on
        // every read.
        if let updated = resolved.updatedCredential {
            _ = ConnectorCredentials.save(updated, for: instance.id)
        }

        let calendarIDs = instance.config.googleCalendarIDs ?? ["primary"]
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return ProviderReadOutcome([])
        }
        let formatter = ISO8601DateFormatter()

        var events: [DayEvent] = []
        for calendarID in calendarIDs {
            var components = URLComponents(string: "\(Self.base)/calendars/\(calendarID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? calendarID)/events")!
            components.queryItems = [
                .init(name: "timeMin", value: formatter.string(from: startOfDay)),
                .init(name: "timeMax", value: formatter.string(from: endOfDay)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "maxResults", value: "50"),
            ]
            guard let url = components.url else { continue }
            do {
                let json = try await ConnectorHTTP.getJSON(url, token: resolved.token)
                events += Self.parseEvents(json, instanceLabel: instance.displayLabel)
            } catch let failure as ConnectorHTTP.Failure {
                return ProviderReadOutcome([], error: failure.connectorError)
            } catch {
                return ProviderReadOutcome([], error: .credentialInvalid)
            }
        }
        return ProviderReadOutcome(events.sorted { $0.start < $1.start })
    }

    /// `EventReadingProvider` is synchronous because EventKit is a local store. A
    /// network provider can't honour that, so this returns empty and the async path
    /// above is what `DaySummaryService` actually calls for API-backed instances.
    /// Kept rather than split into two protocols because every other member is shared.
    func todaysEvents(for instance: ConnectorInstance, now: Date) -> ProviderReadOutcome<[DayEvent]> {
        ProviderReadOutcome([])
    }

    /// Which calendars this account exposes — the picker's data for an API-backed
    /// instance, the analogue of `CalendarConnector.availableCalendars`.
    func calendarList(credential: ConnectorCredential) async -> [(id: String, title: String)] {
        guard let token = credential.accessToken else { return [] }
        guard let url = URL(string: "\(Self.base)/users/me/calendarList?maxResults=100") else { return [] }
        guard let json = try? await ConnectorHTTP.getJSON(url, token: token),
              let items = json["items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return (id, (item["summary"] as? String) ?? id)
        }
    }

    // MARK: - Parsing

    static func parseEvents(_ json: [String: Any], instanceLabel: String) -> [DayEvent] {
        guard let items = json["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item -> DayEvent? in
            // A cancelled instance of a recurring event still appears in the feed.
            guard (item["status"] as? String) != "cancelled" else { return nil }
            let start = item["start"] as? [String: Any] ?? [:]
            let end = item["end"] as? [String: Any] ?? [:]
            // `date` (not `dateTime`) is how the API marks an all-day event.
            let isAllDay = start["date"] != nil
            guard let startDate = Self.parseSlot(start), let endDate = Self.parseSlot(end) else { return nil }
            return DayEvent(
                id: (item["id"] as? String) ?? UUID().uuidString,
                title: ((item["summary"] as? String) ?? "Untitled")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                start: startDate,
                end: endDate,
                isAllDay: isAllDay,
                calendarTitle: (item["organizer"] as? [String: Any])?["displayName"] as? String ?? "",
                sourceTitle: "Google",
                instanceLabel: instanceLabel)
        }
    }

    private static func parseSlot(_ slot: [String: Any]) -> Date? {
        if let dateTime = slot["dateTime"] as? String {
            return ConnectorHTTP.parseISO8601(dateTime)
        }
        if let date = slot["date"] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = .current
            return formatter.date(from: date)
        }
        return nil
    }
}
