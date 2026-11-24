import Foundation

/// A calendar provider that can change or delete one event it read.
///
/// `ToolRegistry` offers `update_calendar_event` and `delete_calendar_event` only on a
/// connection whose provider conforms, so a read-only calendar (Zoom) never gets them.
/// The router reads the day through `eventsToEdit`, resolves the spoken title to one
/// event, and the card runs before `performEdit`.
@MainActor
protocol CalendarEditingProvider: WriteCapableProvider {
    /// The events of `day` on this connection, which an edit is resolved against.
    func eventsToEdit(on day: Date, instance: ConnectorInstance) async -> ProviderReadOutcome<[DayEvent]>
    /// Change or delete the one occurrence in `edit`, never the rest of its series.
    func performEdit(_ edit: CalendarEdit, instance: ConnectorInstance) async -> WriteResult
}

// MARK: - EventKit

extension EventKitCalendarProvider: CalendarEditingProvider {
    func eventsToEdit(on day: Date, instance: ConnectorInstance) async -> ProviderReadOutcome<[DayEvent]> {
        todaysEvents(for: instance, now: day)
    }

    func performEdit(_ edit: CalendarEdit, instance: ConnectorInstance) async -> WriteResult {
        do {
            let calendarTitle = try CalendarConnector.shared.edit(
                eventID: edit.eventID, start: edit.start, change: edit.change)
            return .done(edit.receipt(on: calendarTitle.isEmpty ? instance.displayLabel : calendarTitle))
        } catch let error as CalendarWriteError {
            return .failed(error.message)
        } catch {
            return .failed("Couldn't change the event: \(error.localizedDescription)")
        }
    }
}

// MARK: - Google Calendar

extension GoogleCalendarProvider: CalendarEditingProvider {
    func eventsToEdit(on day: Date, instance: ConnectorInstance) async -> ProviderReadOutcome<[DayEvent]> {
        await todaysEventsAsync(for: instance, now: day)
    }

    /// PATCH or DELETE on the occurrence's own id. `singleEvents=true` gave each
    /// occurrence of a series its own id, so neither call reaches the series.
    /// `calendar.events`, in the sign-in scopes, allows both.
    func performEdit(_ edit: CalendarEdit, instance: ConnectorInstance) async -> WriteResult {
        let token: String
        do { token = try await CredentialStrategy.resolveAndPersist(for: instance) } catch {
            return .failed("Google credential unusable.")
        }
        let calendarID = edit.calendarID ?? instance.config.googleCalendarIDs?.first ?? "primary"
        guard let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/"
            + "\(ConnectorHTTP.pathSegment(calendarID))/events/\(ConnectorHTTP.pathSegment(edit.eventID))")
        else { return .failed("Bad event id.") }
        do {
            switch edit.change {
            case .update(let title, let start, let end):
                var body: [String: Any] = [:]
                body["summary"] = title
                if let start, let end {
                    body["start"] = ["dateTime": ConnectorHTTP.iso8601(from: start)]
                    body["end"] = ["dateTime": ConnectorHTTP.iso8601(from: end)]
                }
                try await ConnectorHTTP.send("PATCH", url, token: token, body: body)
            case .delete:
                try await ConnectorHTTP.send("DELETE", url, token: token)
            }
            return .done(edit.receipt(on: instance.displayLabel))
        } catch ConnectorHTTP.Failure.badStatus(_, let detail) {
            return .failed("Google refused: \(detail.prefix(200))")
        } catch ConnectorHTTP.Failure.unauthorized {
            return .failed("Google didn't allow changing that event.")
        } catch {
            return .failed("Couldn't change the event.")
        }
    }
}

// MARK: - Outlook over Graph

extension OutlookGraphProvider: CalendarEditingProvider {
    func eventsToEdit(on day: Date, instance: ConnectorInstance) async -> ProviderReadOutcome<[DayEvent]> {
        await todaysEventsAsync(for: instance, now: day)
    }

    /// PATCH or DELETE on the occurrence's own id, which `calendarView` returned.
    func performEdit(_ edit: CalendarEdit, instance: ConnectorInstance) async -> WriteResult {
        let token: String
        do { token = try await CredentialStrategy.resolveAndPersist(for: instance) } catch {
            return .failed("Microsoft credential unusable.")
        }
        // `parseEvents` prefixes the Graph id.
        let id = edit.eventID.hasPrefix("outlook-") ? String(edit.eventID.dropFirst(8)) : edit.eventID
        guard let url = MicrosoftGraph.url("/me/events/\(ConnectorHTTP.pathSegment(id))") else {
            return .failed("Bad event id.")
        }
        do {
            switch edit.change {
            case .update(let title, let start, let end):
                var body: [String: Any] = [:]
                body["subject"] = title
                if let start, let end {
                    body["start"] = ["dateTime": MicrosoftGraph.dateTimeString(start), "timeZone": "UTC"]
                    body["end"] = ["dateTime": MicrosoftGraph.dateTimeString(end), "timeZone": "UTC"]
                }
                try await ConnectorHTTP.send("PATCH", url, token: token, body: body)
            case .delete:
                try await ConnectorHTTP.send("DELETE", url, token: token)
            }
            return .done(edit.receipt(on: instance.displayLabel))
        } catch ConnectorHTTP.Failure.badStatus(_, let detail) {
            return .failed("Outlook refused: \(detail.prefix(200))")
        } catch ConnectorHTTP.Failure.unauthorized {
            return .failed("Outlook didn't allow changing that event. Sign in to Microsoft again.")
        } catch {
            return .failed("Couldn't change the event.")
        }
    }
}

// MARK: - HTTP

extension ConnectorHTTP {
    /// A PATCH or DELETE with a bearer token, the failure taxonomy of `postJSON`. The
    /// body of the answer is not read: a DELETE answers 204 with none.
    static func send(_ method: String,
                     _ url: URL,
                     token: String,
                     body: [String: Any]? = nil,
                     timeout: TimeInterval = 20) async throws {
        guard !token.isEmpty else { throw Failure.unauthorized }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw Failure.unauthorized
        case 429: throw Failure.rateLimited
        default: throw Failure.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// One path segment, every character but a letter or a digit escaped: an id
    /// with a `/` must not become two segments.
    static func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}
