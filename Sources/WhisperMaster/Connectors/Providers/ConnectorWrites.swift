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

// MARK: - Google Calendar

extension GoogleCalendarProvider: WriteCapableProvider {
    func performWrite(tool: String,
                      arguments: [String: String],
                      instance: ConnectorInstance) async -> WriteResult {
        guard tool == "create_calendar_event" else { return .failed("Calendar can't do \(tool).") }
        guard let calendarID = arguments["calendar"],
              let title = arguments["title"],
              let start = arguments["start"],
              let end = arguments["end"]
        else { return .failed("Missing calendar, title, start or end.") }

        // Reject unparseable times here rather than letting Google 400 on them — the
        // model is the likely source and a specific message is what lets it retry.
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
