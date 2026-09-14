import XCTest
@testable import WhisperMaster

/// Channel resolution, plus the gate that decides which built surfaces a
/// channel may open. Every part is pure, so all three channels are covered here
/// without needing three real bundles.
final class ReleaseChannelTests: XCTestCase {

    // MARK: Channel resolution

    private let shipping = ReleaseChannel.shippingBundleID

    /// Stable and beta ship as ONE bundle so Sparkle can update between them, so
    /// the version marker is the only thing that separates them.
    func testTheVersionMarkerSeparatesStableFromBeta() {
        XCTAssertEqual(ReleaseChannel.channel(forVersion: "1.1.0", bundleID: shipping), .stable)
        XCTAssertEqual(ReleaseChannel.channel(forVersion: "1.1.0-beta.9", bundleID: shipping), .beta)
        XCTAssertEqual(ReleaseChannel.channel(forVersion: "1.1.0-dev.1", bundleID: shipping), .dev)
    }

    /// The dev build is still re-badged side-by-side, and a local one may carry
    /// no marker at all, so its id has to answer on its own.
    func testTheDevBundleIsDevWhateverItsVersionSays() {
        XCTAssertEqual(
            ReleaseChannel.channel(forVersion: "1.1.0", bundleID: "app.whispermaster.mac.dev"), .dev)
        XCTAssertEqual(
            ReleaseChannel.channel(forVersion: "1.1.0-beta.9", bundleID: "app.whispermaster.mac.dev"),
            .dev)
    }

    /// A bundle-less `swift build` run and the headless snapshot renderer must
    /// see every surface, so anything unrecognised resolves to `.dev`.
    func testUnknownAndMissingBundlesResolveToDev() {
        XCTAssertEqual(ReleaseChannel.channel(forVersion: "1.1.0", bundleID: nil), .dev)
        XCTAssertEqual(ReleaseChannel.channel(forVersion: "1.1.0", bundleID: ""), .dev)
        XCTAssertEqual(ReleaseChannel.channel(forVersion: "1.1.0", bundleID: "com.example.other"), .dev)
        XCTAssertEqual(ReleaseChannel.channel(forVersion: nil, bundleID: shipping), .dev)
    }

    /// Guards against a near-miss id (a typo'd re-badge in channel.sh) being
    /// silently treated as stable and shipping the gated surfaces open.
    func testSuffixLookalikesAreNotStable() {
        XCTAssertEqual(
            ReleaseChannel.channel(forVersion: "1.1.0", bundleID: "app.whispermaster.mac.beta"), .dev)
        XCTAssertEqual(
            ReleaseChannel.channel(forVersion: "1.1.0", bundleID: "app.whispermaster.macc"), .dev)
    }

    /// `release.sh` refuses a beta release whose version lacks the marker, and
    /// this is the other half of that contract: a marker-less build is stable, so
    /// a forgotten bump can only ever close the gated surfaces, never open them.
    func testAMarkerlessVersionIsStableNotBeta() {
        XCTAssertEqual(ReleaseChannel.channel(forVersion: "1.1.0", bundleID: shipping), .stable)
        XCTAssertEqual(ReleaseChannel.channel(forVersion: "1.1.0-rc1", bundleID: shipping), .stable)
    }

    // MARK: The connectors / notes gate

    /// The staged rollout is over: stable sees the same surfaces beta and dev
    /// do. This is the lock on that decision — a channel check reappearing in
    /// `connectorsAndNotesAvailable(on:)` fails here rather than shipping a
    /// stable build with two dead sidebar rows.
    func testConnectorsAndNotesAreOpenOnEveryChannel() {
        for channel in [ReleaseChannel.stable, .beta, .dev] {
            XCTAssertTrue(
                FeatureFlags.connectorsAndNotesAvailable(on: channel),
                "\(channel.rawValue) must open Connectors and Notes")
        }
    }

    /// The Model Lab does not ride on that change: it downloads gigabytes on
    /// request and can repoint the shipped dictation model, so it stays a dev
    /// bench.
    func testTheModelLabStaysDevOnly() {
        XCTAssertTrue(FeatureFlags.modelLabAvailable(on: .dev))
        XCTAssertFalse(FeatureFlags.modelLabAvailable(on: .beta))
        XCTAssertFalse(FeatureFlags.modelLabAvailable(on: .stable))
    }

    // MARK: Section availability

    /// The closed path is still reachable code — it is what a re-close would
    /// fall back to — so both halves stay covered.
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

/// The per-user half: which appcast items Sparkle is allowed to offer.
final class BetaAccessChannelTests: XCTestCase {

    func testAFlaggedUserIsAllowedTheBetaChannel() {
        XCTAssertEqual(BetaAccess.allowedChannels(isBetaUser: true), ["beta"])
    }

    /// ⚠️ Empty is "stable only", NOT "no updates". Sparkle always offers an item
    /// carrying no `<sparkle:channel>` and consults the allowed set only for
    /// tagged ones, so an unflagged user still receives every stable release.
    /// Read the other way round, this is also why a beta user keeps receiving
    /// stable releases: their set adds beta, it does not replace the default.
    func testAnUnflaggedUserGetsTheDefaultChannelOnly() {
        XCTAssertTrue(BetaAccess.allowedChannels(isBetaUser: false).isEmpty)
    }

    /// The flag never admits the dev channel. Dev is gated by shipping a separate
    /// bundle to a separate feed, not by a per-user setting, so a flipped flag
    /// must not be able to pull a production user onto nightly builds.
    func testTheFlagNeverAdmitsTheDevChannel() {
        XCTAssertFalse(BetaAccess.allowedChannels(isBetaUser: true).contains("dev"))
    }
}
