import XCTest
@testable import WhisperMaster

/// Locks in the `channel` dimension — the one thing that makes stable, beta and
/// dev separable in a single GA data stream.
///
/// It matters more than it looks: a GA custom dimension **cannot be renamed
/// without losing its history**, and all three channels post to one stream, so
/// if `channel` ever stops being emitted the reports don't error — they quietly
/// merge every channel back into one undifferentiated number.
final class AnalyticsChannelTests: XCTestCase {

    func testEveryGoogleEventCarriesTheChannel() throws {
        let channel = try XCTUnwrap(AnalyticsConfig.googleBaseParameters["channel"])
        XCTAssertFalse(channel.isEmpty)
    }

    func testTheChannelIsOneOfTheThreeKnownValues() {
        let known = Set(["stable", "beta", "dev"])
        XCTAssertTrue(known.contains(AnalyticsConfig.googleBaseParameters["channel"] ?? ""))
    }

    /// GA registers this under Admin → Custom definitions as `channel`. The
    /// snake_case transform must leave it alone, or the dimension registered in
    /// the UI and the one arriving on the wire stop matching.
    func testTheChannelParameterNameSurvivesGooglesTransformUnchanged() {
        XCTAssertEqual(GA4Limits.parameterName("channel"), "channel")
    }

    /// The channel rides on every event as base context, and survives the merge
    /// with an event's own params — while `session_id` still outranks both, so
    /// adding this dimension can't be what empties GA's standard reports.
    func testTheChannelReachesTheWireAlongsideACrashEvent() async {
        let client = GoogleAnalyticsClient(
            measurementID: "G-TEST",
            apiSecret: "secret",
            clientID: "client",
            baseParameters: ["channel": "beta", "session_id": "hijacked"],
            useDebugEndpoint: true
        )
        let event = AnalyticsEvent.appCrashed(nil)
        let payload = await client.payload(
            name: event.googleName,
            parameters: event.parameters,
            now: Date()
        )

        let params = payload.events[0].params
        XCTAssertEqual(payload.events[0].name, "app_crashed")
        XCTAssertEqual(params["channel"], "beta")
        XCTAssertEqual(params["has_report"], "false")
        XCTAssertNotEqual(params["session_id"], "hijacked")
    }

    /// `AppDelegate` installs the crash handler from `persistedAnalyticsEnabled`
    /// at the top of launch, while everything else reads `state.analyticsEnabled`.
    /// If those two ever disagreed, the crash handler would be installed for
    /// someone who opted out — or missing for someone who opted in — and neither
    /// is visible from the UI. They must read the same key with the same default.
    @MainActor
    func testTheLaunchTimeOptInMatchesWhatAppStateResolves() {
        XCTAssertEqual(AppState.persistedAnalyticsEnabled, AppState().analyticsEnabled)
    }

    /// Opt-out, not opt-in: absent means on. A default flip here would silently
    /// disable analytics and crash reporting for the entire existing userbase,
    /// since nobody who never touched the toggle has the key written.
    func testAnalyticsDefaultsToOnWhenTheUserHasNeverTouchedTheToggle() {
        let key = AppState.analyticsEnabledDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(AppState.persistedAnalyticsEnabled)

        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(AppState.persistedAnalyticsEnabled)
    }

    /// The build's channel comes from the bundle id `Scripts/channel.sh` badges
    /// in — never from `BetaAccess`, which answers "which appcast should Sparkle
    /// poll" and reports `.beta` for a *stable* build run by a flagged user.
    /// Attributing that user's events to beta would corrupt both channels' counts.
    func testTheChannelIsDerivedFromTheBundleIDNotTheUsersBetaFlag() {
        XCTAssertEqual(ReleaseChannel.channel(forBundleID: "app.whispermaster.mac"), .stable)
        XCTAssertEqual(ReleaseChannel.channel(forBundleID: "app.whispermaster.mac.beta"), .beta)
        XCTAssertEqual(ReleaseChannel.channel(forBundleID: "app.whispermaster.mac.dev"), .dev)
        // A bundle-less `swift build` run reports dev, so local development
        // never lands in the stable numbers.
        XCTAssertEqual(ReleaseChannel.channel(forBundleID: nil), .dev)
    }
}
