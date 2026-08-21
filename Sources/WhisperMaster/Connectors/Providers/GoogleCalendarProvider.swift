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
struct GoogleCalendarProvider: EventReadingProvider, AsyncEventReadingProvider {
    static let kind: ConnectorKind = .googleCalendar

    private static let base = "https://www.googleapis.com/calendar/v3"

    /// Confirms the grant by asking who it belongs to. The returned email is the
    /// instance identity and prefills the label.
    ///
    /// The token is **resolved**, not read straight off the credential: an access token
    /// that has merely expired next to a refresh token that still works is a healthy
    /// connection, and calling Google with the stale one reported it as invalid and
    /// sent the user off to reconnect for nothing. `validate(instance:)` is the form
    /// that can also keep what the refresh returned — this one has no id to save under.
    func validate(_ credential: ConnectorCredential,
                  config: ConnectorConfig) async -> ValidationResult {
        let token: String
        do {
            token = try await CredentialStrategy.refreshedIfNeeded(credential).token
        } catch CredentialStrategy.ResolveError.noCredential {
            return .invalid("No access token on this connection.")
        } catch {
            return .invalid("This connection has expired — sign in to Google again.")
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
        // Resolve-and-persist: a refresh may have produced new tokens, and they're
        // written back once, here, rather than on every read.
        let token: String
        do {
            token = try await CredentialStrategy.resolveAndPersist(for: instance)
        } catch {
            Log.connectors.error(
                "google calendar: credential resolve failed for \(instance.displayLabel, privacy: .public): \(String(describing: error), privacy: .public)")
            return ProviderReadOutcome([], error: CredentialStrategy.connectorError(for: error))
        }

        let calendarIDs = instance.config.googleCalendarIDs ?? ["primary"]
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return ProviderReadOutcome([])
        }
        let formatter = ISO8601DateFormatter()

        // One bad calendar must not blank the account. A Google account carries
        // calendars the user never chose — Birthdays, Holidays, a shared calendar
        // whose access was revoked — and any one of them can refuse while the rest
        // read fine. Failing the whole instance on the first refusal loses every
        // real event; so failures are collected and only *all* of them failing is
        // reported as the instance's error.
        var events: [DayEvent] = []
        var failure: ConnectorError?
        var failedCount = 0
        // What Google actually granted, as opposed to what we asked for — the user
        // can decline individual scopes on the consent screen, and a token that
        // lists calendars but can't read events is exactly what a partial grant
        // looks like. Not a secret (it's a space-separated list of URLs).
        let grantedScope = ConnectorCredentials.load(for: instance.id)?["scope"] ?? "none recorded"
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
                let json = try await ConnectorHTTP.getJSON(url, token: token)
                events += Self.parseEvents(json, instanceLabel: instance.displayLabel)
            } catch let error as ConnectorHTTP.Failure {
                failedCount += 1
                failure = failure ?? error.connectorError
                Log.connectors.error(
                    "google calendar: \(instance.displayLabel, privacy: .public) calendar \(calendarID, privacy: .public) failed: \(String(describing: error), privacy: .public) [granted scope: \(grantedScope, privacy: .public)]")
            } catch {
                failedCount += 1
                failure = failure ?? .credentialInvalid
                Log.connectors.error(
                    "google calendar: \(instance.displayLabel, privacy: .public) calendar \(calendarID, privacy: .public) failed: \(String(describing: error), privacy: .public) [granted scope: \(grantedScope, privacy: .public)]")
            }
        }
        // Every calendar refused → the account itself is the problem, so the row
        // says so. A partial failure is logged and otherwise ignored: the events we
        // did get are worth more than an error badge over them.
        if failedCount == calendarIDs.count, let failure {
            return ProviderReadOutcome([], error: failure)
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
    ///
    /// **Throws rather than returning `[]` on failure.** Swallowing the error here is
    /// what made a missing `calendar.readonly` scope look like "this account has no
    /// calendars": `calendarList.list` answers 403 for a grant that only carries
    /// `calendar.events`, and an empty list is indistinguishable from a real refusal.
    /// The caller needs the difference to say something true.
    func calendarList(credential: ConnectorCredential) async throws -> [(id: String, title: String)] {
        guard let token = credential.accessToken else {
            throw ConnectorHTTP.Failure.unauthorized
        }
        guard let url = URL(string: "\(Self.base)/users/me/calendarList?maxResults=100") else {
            throw ConnectorHTTP.Failure.malformedResponse
        }
        let json = try await ConnectorHTTP.getJSON(url, token: token)
        guard let items = json["items"] as? [[String: Any]] else {
            throw ConnectorHTTP.Failure.malformedResponse
        }
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
