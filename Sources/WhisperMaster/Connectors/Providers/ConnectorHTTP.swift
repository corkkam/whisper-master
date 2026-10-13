import Foundation

/// One thing read out of a non-calendar connector — a Slack mention, a Linear issue, a
/// GitHub review request, an unread mail, a Drive file.
///
/// Deliberately one shape rather than a typed struct per domain. The agent's tools all
/// ask the same question ("what's recent/assigned/unread here"), and inventing
/// `SlackMessage` / `LinearIssue` / `DriveFile` before any surface renders them
/// differently would be speculative structure. When a surface genuinely needs
/// domain-specific fields, that's the moment to split this.
struct ConnectorItem: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    /// One supporting line — a channel name, an author, a due date.
    let detail: String
    let timestamp: Date?
    let url: String?
    /// The connector instance this came from, so a merged answer can name it.
    let instanceLabel: String
    /// Still waiting on the user (unread mail). Only a provider that can tell sets
    /// it; the notch counts these for a tab's badge, so a provider that can't tell
    /// must leave it false rather than guess.
    let isUnread: Bool

    init(id: String, title: String, detail: String = "",
         timestamp: Date? = nil, url: String? = nil, instanceLabel: String = "",
         isUnread: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.timestamp = timestamp
        self.url = url
        self.instanceLabel = instanceLabel
        self.isUnread = isUnread
    }
}

/// A provider that can list recent/assigned/unread items. Covers `.messages`,
/// `.tasks`, `.files` and `.mail` with one method — see `ConnectorItem`.
@MainActor
protocol ItemReadingProvider: ConnectorProvider {
    func recentItems(for instance: ConnectorInstance, limit: Int) async -> ProviderReadOutcome<[ConnectorItem]>
}

/// Shared JSON-over-HTTP plumbing for the network providers.
///
/// Centralised so every provider gets the same timeouts, the same rate-limit
/// detection, and the same rule that a failure is *reported* rather than thrown into a
/// fan-out — one broken connector must not take down a whole answer.
enum ConnectorHTTP {
    enum Failure: Error, Equatable {
        case unauthorized
        case rateLimited
        case transport(String)
        case badStatus(Int, String)
        case malformedResponse

        /// The instance error state this failure becomes on the row.
        var connectorError: ConnectorError {
            switch self {
            case .unauthorized: return .credentialInvalid
            case .rateLimited: return .rateLimited
            // Not the credential's fault — a dropped connection or a status that
            // isn't 401/403 says nothing about the token, and telling the user to
            // reconnect over a 500 sends them through an OAuth flow that can't help.
            case .transport, .badStatus, .malformedResponse: return .unreachable
            }
        }
    }

    /// A JSON GET with a bearer token. 401/403 → `.unauthorized` (the credential is the
    /// problem), 429 → `.rateLimited` (time is the problem) — the distinction is what
    /// lets the UI say something useful instead of "it didn't work".
    static func getJSON(_ url: URL,
                        token: String,
                        headers: [String: String] = [:],
                        timeout: TimeInterval = 20) async throws -> [String: Any] {
        // An empty token is a resolution bug, never a legitimate anonymous call —
        // every endpoint behind this needs a bearer. Sending the request without the
        // header let Google answer 403 "unregistered callers", which is
        // indistinguishable on the row from a token it actually rejected. Fail here
        // instead, where the cause is still legible.
        guard !token.isEmpty else {
            Log.connectors.error(
                "\(url.path, privacy: .public): refusing to call with an empty bearer token")
            throw Failure.unauthorized
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        if !(200..<300).contains(http.statusCode) {
            // 401 and 403 collapse into one case, and "invalid token" vs "insufficient
            // scope" are opposite problems with opposite fixes — so the status and the
            // provider's own words are logged here, once, for every provider.
            // The token is never logged; the path and body are what diagnose this.
            Log.connectors.error(
                "\(url.path, privacy: .public) → \(http.statusCode, privacy: .public): \(String(data: data, encoding: .utf8)?.prefix(400) ?? "", privacy: .public)")
        }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw Failure.unauthorized
        case 429: throw Failure.rateLimited
        default:
            throw Failure.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformedResponse
        }
        return json
    }

    /// Slack answers 200 with `{"ok": false, "error": "invalid_auth"}` rather than an
    /// HTTP status, so its providers route through this to get the same failure taxonomy
    /// as everyone else.
    static func requireSlackOK(_ json: [String: Any]) throws {
        guard (json["ok"] as? Bool) == true else {
            let error = json["error"] as? String ?? "unknown"
            if error.contains("auth") || error.contains("token") { throw Failure.unauthorized }
            if error.contains("ratelimit") { throw Failure.rateLimited }
            throw Failure.badStatus(200, error)
        }
    }

    /// ISO-8601 with or without fractional seconds — providers are inconsistent even
    /// within one API.
    static func parseISO8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    /// The inverse, for a write. Emitted in the **local** time zone with its offset,
    /// because a calendar event at "3pm" means 3pm where the user is; formatting it as
    /// UTC `Z` would file the meeting at the right instant with the wrong wall-clock
    /// reading in every calendar UI that shows the originating zone.
    static func iso8601(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
