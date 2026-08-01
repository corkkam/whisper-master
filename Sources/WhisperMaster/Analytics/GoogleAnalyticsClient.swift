import Foundation

/// Google Analytics 4 for a native macOS app, over the **Measurement Protocol**
/// — a plain HTTPS POST, no SDK.
///
/// **Why not the Google/Firebase SDK.** GA4 has no native macOS SDK. The only
/// first-party route is `FirebaseAnalytics` (macOS support still beta), which
/// drags a closed-source `GoogleAppMeasurement` binary plus a
/// `GoogleService-Info.plist` into an app whose whole pitch is that nothing
/// leaves your device — and it would put a second SDK behind the `Analytics`
/// seam that `CLAUDE.md` says stays one file. The Measurement Protocol lands the
/// same events in the same GA4 property for the cost of one `URLRequest`.
///
/// **Three things the protocol makes us do by hand**, which an SDK would hide:
/// - **`client_id`** is GA's unique-user key. We pass `AnalyticsIdentity.installID`
///   (the random persisted UUID already used as PostHog's `distinct_id`), so GA's
///   user counts work without anything reversible to a person.
/// - **`session_id` + `engagement_time_msec` on every event.** Without them GA
///   files each hit under a zero-second session and the standard reports
///   (Engagement, Retention, most of the Reports tab) stay empty — only Realtime
///   and DebugView show anything. `GA4Session` supplies both.
/// - **Device/OS/app-version context.** A browser tag gets this from the User-Agent;
///   we have no browser, so it rides along as explicit params (see
///   `AnalyticsConfig.googleBaseParameters`). Register them as custom dimensions
///   in GA (Admin → Custom definitions) or they'll only be visible on the event.
///
/// Failures are swallowed by design: analytics must never surface an error or
/// retry into a dictation app's foreground. Note the production endpoint returns
/// `204` even for a malformed payload, so set `WHISPERMASTER_GA_DEBUG=1` to POST
/// to the validation endpoint instead and get the rejection reason in the log.
actor GoogleAnalyticsClient {
    private let measurementID: String
    private let apiSecret: String
    private let clientID: String
    /// Params merged into every event (app version, OS version, channel).
    private let baseParameters: [String: String]
    private let endpoint: URL
    private let isDebugEndpoint: Bool
    private let urlSession: URLSession

    private var session: GA4Session

    init(
        measurementID: String,
        apiSecret: String,
        clientID: String,
        baseParameters: [String: String],
        useDebugEndpoint: Bool,
        now: Date = Date()
    ) {
        self.measurementID = measurementID
        self.apiSecret = apiSecret
        self.clientID = clientID
        self.baseParameters = baseParameters
        self.isDebugEndpoint = useDebugEndpoint
        self.session = GA4Session(now: now)

        let path = useDebugEndpoint ? "/debug/mp/collect" : "/mp/collect"
        var components = URLComponents(string: "https://www.google-analytics.com\(path)")!
        components.queryItems = [
            URLQueryItem(name: "measurement_id", value: measurementID),
            URLQueryItem(name: "api_secret", value: apiSecret),
        ]
        // Force-unwrap is safe: the base string is a literal and both query values
        // are percent-encoded by URLComponents.
        self.endpoint = components.url!

        // Ephemeral: no cookie jar, no disk cache, nothing about analytics
        // persisted to the user's container beyond the install id itself.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        self.urlSession = URLSession(configuration: configuration)
    }

    /// Send one event. Fire-and-forget: any failure is logged at debug and dropped.
    func send(name: String, parameters: [String: String], now: Date = Date()) async {
        let sessionID = session.touch(now: now)
        let merged = baseParameters
            .merging(parameters) { _, event in event }
            .merging(GA4Session.requiredParameters(sessionID: sessionID)) { _, required in required }

        let event = GA4Event(
            name: GA4Limits.eventName(name),
            params: GA4Limits.parameters(merged)
        )
        let payload = GA4Payload(
            clientID: clientID,
            timestampMicros: Int64(now.timeIntervalSince1970 * 1_000_000),
            nonPersonalizedAds: true,
            events: [event]
        )

        guard let body = try? JSONEncoder().encode(payload) else {
            Log.analytics.debug("GA4: could not encode \(event.name, privacy: .public)")
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if isDebugEndpoint {
                // The validation endpoint is the only way to learn *why* GA
                // dropped an event; production answers 204 regardless.
                let text = String(data: data, encoding: .utf8) ?? ""
                Log.analytics.notice(
                    "GA4 debug \(event.name, privacy: .public): \(text, privacy: .public)"
                )
            } else if !(200...299).contains(http.statusCode) {
                Log.analytics.debug(
                    "GA4 \(event.name, privacy: .public) rejected (HTTP \(http.statusCode))"
                )
            }
        } catch {
            // Offline, captive portal, GA blocked by a DNS filter — all expected.
            Log.analytics.debug(
                "GA4 \(event.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

// MARK: - Wire format

/// The Measurement Protocol request body.
///
/// One event per request. Batching (GA allows 25) would need a flush timer and a
/// buffer to lose on quit, for a volume this app will never reach — the events
/// are launch, onboarding, and one per dictation.
struct GA4Payload: Encodable, Equatable {
    let clientID: String
    /// GA rejects hits older than 72 hours; stamping each one keeps ordering
    /// correct when several land in the same second.
    let timestampMicros: Int64
    let nonPersonalizedAds: Bool
    let events: [GA4Event]

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case timestampMicros = "timestamp_micros"
        case nonPersonalizedAds = "non_personalized_ads"
        case events
    }
}

struct GA4Event: Encodable, Equatable {
    let name: String
    let params: [String: String]
}

// MARK: - Sessions

/// GA4's session bookkeeping, done by hand because there's no SDK to do it.
///
/// Pure and clock-injected so `GoogleAnalyticsClientTests` can prove the rollover
/// without waiting half an hour.
struct GA4Session: Equatable {
    /// GA's own definition of a session boundary: 30 minutes without an event.
    static let inactivityTimeout: TimeInterval = 30 * 60

    private(set) var id: String
    private var lastEventAt: Date

    init(now: Date) {
        // GA convention is a seconds-since-epoch integer, unique per session.
        self.id = String(Int(now.timeIntervalSince1970))
        self.lastEventAt = now
    }

    /// Record an event at `now` and return the session id it belongs to,
    /// starting a fresh session if the app sat idle past the timeout.
    mutating func touch(now: Date) -> String {
        if now.timeIntervalSince(lastEventAt) >= Self.inactivityTimeout {
            id = String(Int(now.timeIntervalSince1970))
        }
        lastEventAt = now
        return id
    }

    /// The two params GA needs on **every** event for it to count toward the
    /// standard reports rather than Realtime alone.
    ///
    /// `engagement_time_msec` is deliberately the minimum "1": we don't track
    /// foreground time in a menu-bar app that has no foreground, and inventing a
    /// number would make GA's engagement metrics fiction. Sessions and event
    /// counts stay honest; average engagement time does not apply here.
    static func requiredParameters(sessionID: String) -> [String: String] {
        ["session_id": sessionID, "engagement_time_msec": "1"]
    }
}

// MARK: - Limits

/// The Measurement Protocol's documented limits, applied client-side.
///
/// GA silently discards an event that breaks one of these — the production
/// endpoint still answers `204` — so clamping here is the difference between a
/// truncated value and no data at all.
enum GA4Limits {
    static let maxEventNameLength = 40
    static let maxParameterNameLength = 40
    static let maxParameterValueLength = 100
    static let maxParametersPerEvent = 25

    /// Coerce to GA's event-name rules: letters, digits and underscores only,
    /// must start with a letter, at most 40 characters.
    ///
    /// `AnalyticsEvent.googleName` already emits conforming names; this is the
    /// backstop that keeps a future typo from becoming silently missing data.
    static func eventName(_ raw: String) -> String {
        var cleaned = String(raw.map { character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        })
        if let first = cleaned.first, !first.isLetter {
            cleaned = "e_" + cleaned
        }
        if cleaned.isEmpty { cleaned = "unnamed" }
        return String(cleaned.prefix(maxEventNameLength))
    }

    /// Convert one param name to GA's house style: `wordCountBucket` →
    /// `word_count_bucket`, then the same character rules as an event name.
    ///
    /// This is why `AnalyticsEvent` can keep a single param catalog. PostHog
    /// receives the camelCase names its dashboards already query; GA receives the
    /// snake_case ones its custom dimensions expect — and because a GA custom
    /// dimension can't be renamed without losing its history, getting the
    /// spelling right at first registration is worth this transform.
    /// Already-snake_case names (`session_id`, `app_version`) pass through
    /// unchanged.
    static func parameterName(_ raw: String) -> String {
        var snake = ""
        for character in raw {
            if character.isUppercase, !snake.isEmpty, snake.last != "_" {
                snake.append("_")
            }
            snake.append(contentsOf: character.lowercased())
        }
        return String(eventName(snake).prefix(maxParameterNameLength))
    }

    /// Clamp names and values, then cap the count. Sorted before truncating so
    /// which params survive is deterministic rather than dictionary-order luck.
    static func parameters(_ raw: [String: String]) -> [String: String] {
        let clamped = raw.map { name, value in
            (parameterName(name), String(value.prefix(maxParameterValueLength)))
        }
        let ordered = clamped.sorted { $0.0 < $1.0 }.prefix(maxParametersPerEvent)
        return Dictionary(ordered) { first, _ in first }
    }
}
