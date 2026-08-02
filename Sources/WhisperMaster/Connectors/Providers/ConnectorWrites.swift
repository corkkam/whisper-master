import Foundation

/// A provider that can change something. Separate from the read protocols so a
/// read-only connector cannot be handed a write tool by accident — the type system,
/// not a runtime check, is what keeps `list_messages` and `send_message` apart.
@MainActor
protocol WriteCapableProvider: ConnectorProvider {
    /// Perform a write. `arguments` has already been schema-validated by
    /// `ToolCallParser` **and** authorized by `WriteAuthorizer` — a provider is the last
    /// step, never the place consent is decided.
    func performWrite(tool: String,
                      arguments: [String: String],
                      instance: ConnectorInstance) async -> WriteResult
}

/// What a write did, in the user's words. `summary` is read back in the notch, so a
/// write is never silent.
struct WriteResult: Equatable, Sendable {
    let ok: Bool
    let summary: String

    static func done(_ summary: String) -> WriteResult { WriteResult(ok: true, summary: summary) }
    static func failed(_ summary: String) -> WriteResult { WriteResult(ok: false, summary: summary) }
}

extension ConnectorHTTP {
    /// A JSON POST with a bearer token. Same failure taxonomy as `getJSON`.
    static func postJSON(_ url: URL,
                         token: String,
                         body: [String: Any],
                         headers: [String: String] = [:],
                         timeout: TimeInterval = 20) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw Failure.unauthorized
        case 429: throw Failure.rateLimited
        default: throw Failure.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformedResponse
        }
        return json
    }
}

// MARK: - Slack

extension SlackProvider: WriteCapableProvider {
    func performWrite(tool: String,
                      arguments: [String: String],
                      instance: ConnectorInstance) async -> WriteResult {
        guard tool == "send_message" else { return .failed("Slack can't do \(tool).") }
        guard let channel = arguments["channel"], let text = arguments["text"] else {
            return .failed("Missing channel or text.")
        }
        let resolved: CredentialStrategy.Resolved
        do { resolved = try await CredentialStrategy.resolve(for: instance) } catch {
            return .failed("Slack credential unusable.")
        }
        do {
            let json = try await ConnectorHTTP.postJSON(
                URL(string: "https://slack.com/api/chat.postMessage")!,
                token: resolved.token,
                body: ["channel": channel, "text": text])
            try ConnectorHTTP.requireSlackOK(json)
            return .done("Posted to \(channel) on \(instance.displayLabel).")
        } catch ConnectorHTTP.Failure.badStatus(_, let detail) {
            // Slack's own error names are the useful thing here — `channel_not_found`
            // and `not_in_channel` are different user problems.
            return .failed("Slack refused: \(detail)")
        } catch {
            return .failed("Couldn't post to Slack.")
        }
    }
}

// MARK: - EventKit calendars

/// The write half of the calendar connector every user actually has.
///
/// `create_calendar_event` is published whenever *any* `.events` connection exists,
/// but only the API-backed Google provider could ever serve it — so on the common
/// setup (a calendar added through macOS, which is the only route the add sheet
/// offers without a Google sign-in) "put it in my calendar" reached the router,
/// resolved to a real instance, and then failed with "X can't be written to".
/// EventKit's full-access grant already covers writing, so the capability was there
/// the whole time; nothing was wired to it.
extension EventKitCalendarProvider: WriteCapableProvider {
    func performWrite(tool: String,
                      arguments: [String: String],
                      instance: ConnectorInstance) async -> WriteResult {
        guard tool == "create_calendar_event" else { return .failed("A calendar can't do \(tool).") }
        // Times are stamped by `ToolRouter.resolveWriteTimes`, never by the model.
        guard let title = arguments["title"],
              let start = ConnectorHTTP.parseISO8601(arguments["start"]),
              let end = ConnectorHTTP.parseISO8601(arguments["end"])
        else { return .failed("Missing title or time.") }

        do {
            let calendarTitle = try CalendarConnector.shared.createEvent(
                title: title,
                start: start,
                end: end,
                calendarIdentifiers: instance.config.calendarIdentifiers ?? [])
            return .done("Added \u{201C}\(title)\u{201D} to \(calendarTitle) at \(Self.time.string(from: start)).")
        } catch let error as CalendarWriteError {
            return .failed(error.message)
        } catch {
            return .failed("Couldn't add the event: \(error.localizedDescription)")
        }
    }

    private static var time: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a 'on' EEEE d MMMM"
        return formatter
    }
}

// MARK: - Google Calendar

extension GoogleCalendarProvider: WriteCapableProvider {
    func performWrite(tool: String,
                      arguments: [String: String],
                      instance: ConnectorInstance) async -> WriteResult {
        guard tool == "create_calendar_event" else { return .failed("Calendar can't do \(tool).") }
        // `start`/`end` are stamped by `ToolRouter.resolveWriteTimes` from the user's
        // spoken phrase — the model never supplies a date. `calendar` likewise comes
        // from the instance the user named, not from an id the model guessed: this
        // used to ask a 3B for a raw Google calendar id, which it could only invent.
        guard let title = arguments["title"],
              let start = arguments["start"],
              let end = arguments["end"]
        else { return .failed("Missing title or time.") }
        let calendarID = instance.config.googleCalendarIDs?.first ?? "primary"

        // Reject unparseable times here rather than letting Google 400 on them — a
        // specific message is what lets the caller retry.
        guard ConnectorHTTP.parseISO8601(start) != nil, ConnectorHTTP.parseISO8601(end) != nil else {
            return .failed("Start and end must be ISO-8601 times.")
        }

        let resolved: CredentialStrategy.Resolved
        do { resolved = try await CredentialStrategy.resolve(for: instance) } catch {
            return .failed("Google credential unusable.")
        }
        if let updated = resolved.updatedCredential {
            _ = ConnectorCredentials.save(updated, for: instance.id)
        }

        let encoded = calendarID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? calendarID
        guard let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encoded)/events") else {
            return .failed("Bad calendar id.")
        }
        do {
            _ = try await ConnectorHTTP.postJSON(url, token: resolved.token, body: [
                "summary": title,
                "start": ["dateTime": start],
                "end": ["dateTime": end],
            ])
            return .done("Added \u{201C}\(title)\u{201D} to \(instance.displayLabel).")
        } catch ConnectorHTTP.Failure.badStatus(_, let detail) {
            return .failed("Google refused: \(detail)")
        } catch {
            return .failed("Couldn't create the event.")
        }
    }
}
