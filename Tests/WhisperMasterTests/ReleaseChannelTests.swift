import XCTest
@testable import WhisperMaster

/// The build-channel gate that decides whether Connectors and Notes & Reminders
/// are reachable. Both halves are pure, so both channels are covered here
/// without needing three real bundles.
final class ReleaseChannelTests: XCTestCase {

    // MARK: Channel resolution

    func testBundleIDsMapToTheirChannels() {
        XCTAssertEqual(ReleaseChannel.channel(forBundleID: "app.whispermaster.mac"), .stable)
        XCTAssertEqual(ReleaseChannel.channel(forBundleID: "app.whispermaster.mac.beta"), .beta)
        XCTAssertEqual(ReleaseChannel.channel(forBundleID: "app.whispermaster.mac.dev"), .dev)
    }

    /// A bundle-less `swift build` run and the headless snapshot renderer must
    /// see every surface, so anything unrecognised resolves to `.dev`.
    func testUnknownAndMissingBundleIDsResolveToDev() {
        XCTAssertEqual(ReleaseChannel.channel(forBundleID: nil), .dev)
        XCTAssertEqual(ReleaseChannel.channel(forBundleID: ""), .dev)
        XCTAssertEqual(ReleaseChannel.channel(forBundleID: "com.example.other"), .dev)
    }

    /// Guards against a near-miss id (a typo'd re-badge in channel.sh) being
    /// silently treated as stable and shipping the gated surfaces open.
    func testSuffixLookalikesAreNotStable() {
        XCTAssertEqual(ReleaseChannel.channel(forBundleID: "app.whispermaster.mac.beta.old"), .dev)
        XCTAssertEqual(ReleaseChannel.channel(forBundleID: "app.whispermaster.macc"), .dev)
    }

    // MARK: Section availability

    func testConnectorsAndNotesAreClosedWhenTheFeatureIsUnreleased() {
        XCTAssertFalse(SettingsSection.connectors.isAvailable(connectorsAndNotes: false))
        XCTAssertFalse(SettingsSection.notes.isAvailable(connectorsAndNotes: false))
    }

    func testConnectorsAndNotesOpenWhenTheFeatureIsReleased() {
        XCTAssertTrue(SettingsSection.connectors.isAvailable(connectorsAndNotes: true))
        XCTAssertTrue(SettingsSection.notes.isAvailable(connectorsAndNotes: true))
    }

    /// Gating those two must not take anything else down with it — Today and
    /// Settings in particular, since Today is the fallback the redirect uses.
    /// Nearby Macs is the one section held back on its own (it is on hold).
    func testEveryOtherSectionStaysAvailableWhenTheFeatureIsUnreleased() {
        let gated: Set<SettingsSection> = [.connectors, .notes, .mesh]
        for section in SettingsSection.allCases where !gated.contains(section) {
            XCTAssertTrue(
                section.isAvailable(connectorsAndNotes: false),
                "\(section.rawValue) must stay reachable on stable")
        }
    }

    /// Nearby Macs is closed on every channel, not only stable — it does not ride
    /// on the connectors/notes flag.
    func testNearbyMacsIsOnHoldOnEveryChannel() {
        XCTAssertFalse(SettingsSection.mesh.isAvailable(connectorsAndNotes: false))
        XCTAssertFalse(SettingsSection.mesh.isAvailable(connectorsAndNotes: true))
    }

    /// The sidebar keeps listing all four primaries either way — the gated ones
    /// render as "Soon" rather than disappearing, so the roadmap stays visible.
    func testSidebarStillListsAllFourPrimariesWhenGated() {
        XCTAssertEqual(SettingsSection.primary, [.today, .notes, .connectors, .settings])
    }
}
