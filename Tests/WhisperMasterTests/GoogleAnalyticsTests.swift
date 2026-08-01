import XCTest
@testable import WhisperMaster

/// Covers the pure half of the GA4 Measurement Protocol integration: the parts
/// that decide whether Google keeps an event or silently discards it.
///
/// The stakes are why these exist at all — GA's production endpoint answers
/// `204` for a payload it is about to throw away, so a name or limit violation
/// shows up as *no data*, weeks later, with nothing in the log. Everything
/// checkable without a network is checked here.
final class GoogleAnalyticsTests: XCTestCase {

    // MARK: - Event names

    func testEveryEventNameIsAcceptedByGA() {
        let events: [AnalyticsEvent] = [
            .appLaunched,
            .onboardingFinished,
            .dictationCompleted(engine: "slidingWindow", duration: 12, wordCount: 30),
            .permissionState(accessibility: true, microphone: true),
            .updateInstalled(from: "0.1.0", to: "0.2.0"),
            .cleanupModelDownloaded,
        ]

        for event in events {
            let name = event.googleName
            XCTAssertLessThanOrEqual(name.count, GA4Limits.maxEventNameLength, "\(name) too long")
            XCTAssertNotNil(
                name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression),
                "\(name) is not a legal GA4 event name"
            )
            // A name that needs sanitizing is a name GA would have rejected.
            XCTAssertEqual(GA4Limits.eventName(name), name)
        }
    }

    func testEventNamesAvoidGoogleReservedNamesAndPrefixes() {
        // GA drops these on arrival; each is a name a dictation app could
        // plausibly have reached for.
        let reserved: Set<String> = [
            "first_open", "first_visit", "session_start", "user_engagement",
            "app_remove", "app_store_refund", "in_app_purchase", "ad_activeview",
        ]
        let reservedPrefixes = ["ga_", "google_", "firebase_"]

        let names = [
            AnalyticsEvent.appLaunched,
            .onboardingFinished,
            .dictationCompleted(engine: "e", duration: 1, wordCount: 1),
            .permissionState(accessibility: false, microphone: false),
            .updateInstalled(from: "a", to: "b"),
            .cleanupModelDownloaded,
        ].map(\.googleName)

        for name in names {
            XCTAssertFalse(reserved.contains(name), "\(name) is reserved by GA4")
            for prefix in reservedPrefixes {
                XCTAssertFalse(name.hasPrefix(prefix), "\(name) uses the reserved prefix \(prefix)")
            }
        }
    }

    func testEventNameSanitizerCoercesIllegalNames() {
        // The dotted PostHog spelling is the exact thing GA rejects — proving the
        // backstop catches it is proving a future copy-paste can't lose data.
        XCTAssertEqual(GA4Limits.eventName("App.launched"), "App_launched")
        XCTAssertEqual(GA4Limits.eventName("dictation completed!"), "dictation_completed_")
        // Must start with a letter.
        XCTAssertEqual(GA4Limits.eventName("2fa_enabled"), "e_2fa_enabled")
        XCTAssertEqual(GA4Limits.eventName("_leading"), "e__leading")
        XCTAssertEqual(GA4Limits.eventName(""), "unnamed")
        XCTAssertEqual(
            GA4Limits.eventName(String(repeating: "a", count: 60)).count,
            GA4Limits.maxEventNameLength
        )
    }

    // MARK: - Parameters

    func testParameterNamesAreConvertedToSnakeCase() {
        // The single-catalog rule: PostHog keeps camelCase, GA gets snake_case,
        // and nobody maintains two dictionaries.
        XCTAssertEqual(GA4Limits.parameterName("wordCountBucket"), "word_count_bucket")
        XCTAssertEqual(GA4Limits.parameterName("durationBucket"), "duration_bucket")
        XCTAssertEqual(GA4Limits.parameterName("fromVersion"), "from_version")
        // Already-snake_case names must survive untouched, or the base params and
        // GA's own required params would get mangled.
        XCTAssertEqual(GA4Limits.parameterName("session_id"), "session_id")
        XCTAssertEqual(GA4Limits.parameterName("engagement_time_msec"), "engagement_time_msec")
        XCTAssertEqual(GA4Limits.parameterName("app_version"), "app_version")
    }

    func testParametersAreClampedToGoogleLimits() {
        var oversized: [String: String] = [
            "value": String(repeating: "x", count: 250),
            String(repeating: "n", count: 60): "short",
        ]
        for index in 0..<40 { oversized["param\(index)"] = "v" }

        let clamped = GA4Limits.parameters(oversized)

        XCTAssertLessThanOrEqual(clamped.count, GA4Limits.maxParametersPerEvent)
        for (name, value) in clamped {
            XCTAssertLessThanOrEqual(name.count, GA4Limits.maxParameterNameLength)
            XCTAssertLessThanOrEqual(value.count, GA4Limits.maxParameterValueLength)
        }
        // Deterministic (sorted) truncation, not dictionary-order luck.
        XCTAssertEqual(GA4Limits.parameters(oversized), clamped)
    }

    func testRealEventParametersSurviveConversionUnchangedInMeaning() {
        let event = AnalyticsEvent.dictationCompleted(
            engine: "slidingWindow", duration: 42, wordCount: 30
        )
        let converted = GA4Limits.parameters(event.parameters)

        XCTAssertEqual(converted["engine"], "slidingWindow")
        XCTAssertEqual(converted["duration_bucket"], "30-60s")
        XCTAssertEqual(converted["word_count_bucket"], "25-49")
    }

    // MARK: - Sessions

    func testSessionIDIsStableWithinTheTimeout() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var session = GA4Session(now: start)
        let first = session.touch(now: start)

        XCTAssertEqual(session.touch(now: start.addingTimeInterval(60)), first)
        XCTAssertEqual(session.touch(now: start.addingTimeInterval(29 * 60)), first)
    }

    func testSessionRollsOverAfterThirtyIdleMinutes() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var session = GA4Session(now: start)
        let first = session.touch(now: start)

        let second = session.touch(now: start.addingTimeInterval(GA4Session.inactivityTimeout))
        XCTAssertNotEqual(second, first)
    }

    func testIdleClockRunsFromTheLastEventNotTheSessionStart() {
        // A user dictating every 20 minutes for two hours is one session, not
        // six — the timeout is measured from the last event, not from the start.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var session = GA4Session(now: start)
        let first = session.touch(now: start)

        for step in 1...6 {
            let id = session.touch(now: start.addingTimeInterval(Double(step) * 20 * 60))
            XCTAssertEqual(id, first, "step \(step) should still be the same session")
        }
    }

    func testRequiredParametersAreAlwaysPresent() {
        // Without both of these GA files the hit under a zero-second session and
        // the standard reports stay empty — the failure mode is "Realtime works,
        // everything else is blank".
        let required = GA4Session.requiredParameters(sessionID: "1700000000")
        XCTAssertEqual(required["session_id"], "1700000000")
        XCTAssertEqual(required["engagement_time_msec"], "1")
    }

    // MARK: - Wire format

    func testPayloadEncodesTheKeysGoogleExpects() throws {
        let payload = GA4Payload(
            clientID: "abc-123",
            timestampMicros: 1_700_000_000_000_000,
            nonPersonalizedAds: true,
            events: [GA4Event(name: "app_launched", params: ["session_id": "1"])]
        )

        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["client_id"] as? String, "abc-123")
        XCTAssertEqual(json["timestamp_micros"] as? Int64, 1_700_000_000_000_000)
        XCTAssertEqual(json["non_personalized_ads"] as? Bool, true)

        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["name"] as? String, "app_launched")
        XCTAssertEqual((events[0]["params"] as? [String: String])?["session_id"], "1")
    }

    // MARK: - The body actually posted

    /// Builds a client with the same shape the app does, and checks the real
    /// bytes rather than a hand-written approximation of them.
    private func makeClient(now: Date) -> GoogleAnalyticsClient {
        GoogleAnalyticsClient(
            measurementID: "G-TESTID0000",
            apiSecret: "test-secret",
            clientID: "11111111-2222-3333-4444-555555555555",
            baseParameters: ["app_version": "1.2.9-beta.1", "platform": "macos"],
            useDebugEndpoint: true,
            now: now
        )
    }

    func testPayloadMergesBaseEventAndRequiredParamsInThatOrder() async {
        let now = Date(timeIntervalSince1970: 1_785_600_000)
        let client = makeClient(now: now)

        let payload = await client.payload(
            name: AnalyticsEvent.dictationCompleted(
                engine: "slidingWindow", duration: 42, wordCount: 30
            ).googleName,
            parameters: AnalyticsEvent.dictationCompleted(
                engine: "slidingWindow", duration: 42, wordCount: 30
            ).parameters,
            now: now
        )

        let params = payload.events[0].params
        XCTAssertEqual(payload.events[0].name, "dictation_completed")
        XCTAssertEqual(payload.clientID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(payload.timestampMicros, 1_785_600_000_000_000)
        // Base context survives...
        XCTAssertEqual(params["app_version"], "1.2.9-beta.1")
        XCTAssertEqual(params["platform"], "macos")
        // ...the event's own params arrive snake_cased...
        XCTAssertEqual(params["duration_bucket"], "30-60s")
        XCTAssertEqual(params["word_count_bucket"], "25-49")
        // ...and GA's required pair is present.
        XCTAssertEqual(params["session_id"], "1785600000")
        XCTAssertEqual(params["engagement_time_msec"], "1")
    }

    func testEventParamsOverrideBaseButNeverTheRequiredSessionParams() async {
        let now = Date(timeIntervalSince1970: 1_785_600_000)
        let client = makeClient(now: now)

        let payload = await client.payload(
            name: "app_launched",
            parameters: [
                // An event trying to shadow the base context: allowed.
                "app_version": "override-me",
                // An event trying to shadow GA's session bookkeeping: must lose,
                // or the standard reports quietly go empty.
                "session_id": "hijacked",
                "engagement_time_msec": "999999",
            ],
            now: now
        )

        let params = payload.events[0].params
        XCTAssertEqual(params["app_version"], "override-me")
        XCTAssertEqual(params["session_id"], "1785600000")
        XCTAssertEqual(params["engagement_time_msec"], "1")
    }

    // MARK: - Configuration gating

    func testGoogleStaysDormantWithoutBothCredentials() throws {
        // The half-substituted-build-setting case: a non-empty string GA would
        // accept and then drop every event for.
        XCTAssertNil("$(GA_MEASUREMENT_ID)".range(of: "^G-[A-Z0-9]+$", options: .regularExpression))
        XCTAssertNil("".range(of: "^G-[A-Z0-9]+$", options: .regularExpression))
        XCTAssertNotNil("G-ABC123XYZ9".range(of: "^G-[A-Z0-9]+$", options: .regularExpression))

        // With no credentials in the environment the real gate must be off — a
        // `swift test` bundle has no Info.plist, so this is the shipped default.
        // Skipped rather than failed when a developer has exported the overrides
        // to test against a live property.
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            (environment["WHISPERMASTER_GA_MEASUREMENT_ID"] ?? "").isEmpty
                && (environment["WHISPERMASTER_GA_API_SECRET"] ?? "").isEmpty,
            "GA overrides are exported in this shell"
        )
        XCTAssertFalse(AnalyticsConfig.isGoogleConfigured)
    }

    func testBaseParametersAreGALegalAndContentFree() {
        let base = AnalyticsConfig.googleBaseParameters
        XCTAssertEqual(base["platform"], "macos")
        XCTAssertNotNil(base["app_version"])
        XCTAssertNotNil(base["os_version"])

        for (name, value) in GA4Limits.parameters(base) {
            XCTAssertNotNil(name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression))
            XCTAssertLessThanOrEqual(value.count, GA4Limits.maxParameterValueLength)
        }
    }
}
