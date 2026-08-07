import XCTest
@testable import WhisperMaster

/// The version arithmetic the whole surface rests on. A string comparison here
/// would put "1.10.0" below "1.9.0" and silently stop showing release notes
/// forever after `.9` — which is exactly the bug these cases exist to prevent.
final class SemanticVersionTests: XCTestCase {
    func testDoubleDigitMinorSortsAboveSingleDigit() {
        XCTAssertLessThan(SemanticVersion("1.9.0")!, SemanticVersion("1.10.0")!)
        XCTAssertGreaterThan(SemanticVersion("1.10.0")!, SemanticVersion("1.9.0")!)
    }

    func testDoubleDigitPatchSortsAboveSingleDigit() {
        XCTAssertLessThan(SemanticVersion("1.2.9")!, SemanticVersion("1.2.10")!)
    }

    func testComponentsAreComparedLeftToRight() {
        XCTAssertLessThan(SemanticVersion("1.0.0")!, SemanticVersion("2.0.0")!)
        XCTAssertLessThan(SemanticVersion("1.2.0")!, SemanticVersion("1.3.0")!)
        XCTAssertGreaterThan(SemanticVersion("2.0.0")!, SemanticVersion("1.99.99")!)
    }

    func testMissingComponentsDefaultToZero() {
        XCTAssertEqual(SemanticVersion("1"), SemanticVersion("1.0.0"))
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion("1.2.0"))
    }

    func testALeadingVIsTolerated() {
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion("1.2.3"))
    }

    func testBuildMetadataIsIgnoredForPrecedence() {
        XCTAssertEqual(SemanticVersion("1.2.3+build.99"), SemanticVersion("1.2.3"))
    }

    /// The channel markers this repo requires on non-stable versions
    /// (`-beta.N` / `-dev.N`) must not read as *newer* than the release they
    /// lead to, or a beta tester would never see the stable note.
    func testAPrereleaseSortsBelowItsRelease() {
        XCTAssertLessThan(SemanticVersion("1.3.0-beta.2")!, SemanticVersion("1.3.0")!)
        XCTAssertLessThan(SemanticVersion("1.3.0-dev.1")!, SemanticVersion("1.3.0")!)
    }

    /// Alphabetical, per semver — *not* a channel ranking. Nothing should read a
    /// beta-vs-dev ordering as meaningful; a user is only ever on one channel,
    /// and what matters is that both sit below the stable release above.
    func testPrereleaseIdentifiersCompareAlphabetically() {
        XCTAssertLessThan(SemanticVersion("1.3.0-beta.1")!, SemanticVersion("1.3.0-dev.1")!)
    }

    func testNumericPrereleaseIdentifiersCompareNumerically() {
        XCTAssertLessThan(SemanticVersion("1.3.0-beta.2")!, SemanticVersion("1.3.0-beta.10")!)
    }

    /// `AppInfo.version` reports "—" when there is no bundle, which is what a
    /// `swift test` run and the headless snapshot renderer both see.
    func testUnparseableVersionsReturnNil() {
        XCTAssertNil(SemanticVersion("—"))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("not.a.version"))
        XCTAssertNil(SemanticVersion("1.2.3.4"))
        XCTAssertNil(SemanticVersion("-1.0.0"))
    }
}

/// Which launches have earned the window.
final class WhatsNewGateTests: XCTestCase {
    /// The rule that keeps a brand-new user out of a release note about a
    /// release they were never here for — they get the notch onboarding instead.
    func testAFirstInstallRecordsTheVersionAndShowsNothing() {
        XCTAssertEqual(
            WhatsNewGate.decide(currentVersion: "1.1.0", lastSeenVersion: nil),
            .firstInstall
        )
    }

    func testAGenuineUpgradeShows() {
        XCTAssertEqual(
            WhatsNewGate.decide(currentVersion: "1.1.0", lastSeenVersion: "1.0.0"),
            .show
        )
    }

    /// The case a string comparison gets wrong.
    func testAnUpgradePastNineShows() {
        XCTAssertEqual(
            WhatsNewGate.decide(currentVersion: "1.10.0", lastSeenVersion: "1.9.0"),
            .show
        )
    }

    func testARelaunchOnTheSameVersionShowsNothing() {
        XCTAssertEqual(
            WhatsNewGate.decide(currentVersion: "1.1.0", lastSeenVersion: "1.1.0"),
            .upToDate
        )
    }

    /// A rolled-back install is not news.
    func testADowngradeShowsNothing() {
        XCTAssertEqual(
            WhatsNewGate.decide(currentVersion: "1.0.0", lastSeenVersion: "1.1.0"),
            .upToDate
        )
    }

    /// An unreadable running version must not be recorded or announced —
    /// recording "—" would burn the next real upgrade.
    func testAnUnreadableCurrentVersionShowsNothing() {
        XCTAssertEqual(
            WhatsNewGate.decide(currentVersion: "—", lastSeenVersion: "1.0.0"),
            .upToDate
        )
        XCTAssertEqual(
            WhatsNewGate.decide(currentVersion: "—", lastSeenVersion: nil),
            .upToDate
        )
    }

    /// A corrupt stored value is treated as unset: catch up quietly rather than
    /// showing a note that may be years stale.
    func testAnUnreadableStoredVersionIsTreatedAsAFirstInstall() {
        XCTAssertEqual(
            WhatsNewGate.decide(currentVersion: "1.1.0", lastSeenVersion: "garbage"),
            .firstInstall
        )
    }
}

/// Decoding the published contract. Forgiving in one direction only: unknown
/// keys are ignored, bad entries are dropped, and nothing here may throw its way
/// into blocking a launch.
final class WhatsNewManifestTests: XCTestCase {
    private func decode(_ json: String) throws -> WhatsNewManifest {
        try JSONDecoder().decode(WhatsNewManifest.self, from: Data(json.utf8))
    }

    func testAFullReleaseDecodes() throws {
        let manifest = try decode("""
        {
          "schemaVersion": 1,
          "releases": [
            {
              "version": "1.1.0",
              "headline": "Voice notes, everywhere",
              "publishedAt": "2026-08-07T00:00:00Z",
              "videoURL": "https://dl.corkkam.com/whats-new/1.1.0.mp4",
              "posterURL": "https://dl.corkkam.com/whats-new/1.1.0.jpg",
              "highlights": [
                { "title": "Keeps the recording", "body": "Play it back later.", "systemImage": "waveform" }
              ]
            }
          ]
        }
        """)

        XCTAssertEqual(manifest.releases.count, 1)
        let release = try XCTUnwrap(manifest.releases.first)
        XCTAssertEqual(release.version, "1.1.0")
        XCTAssertEqual(release.headline, "Voice notes, everywhere")
        XCTAssertNotNil(release.publishedAt)
        XCTAssertTrue(release.hasVideo)
        XCTAssertEqual(release.highlights.count, 1)
        XCTAssertEqual(release.highlights.first?.systemImage, "waveform")
    }

    /// The publish side must be able to add keys without breaking shipped apps.
    func testUnknownKeysAreIgnored() throws {
        let manifest = try decode("""
        {
          "schemaVersion": 1,
          "somethingNew": { "nested": true },
          "releases": [
            { "version": "1.1.0", "headline": "Hello", "futureField": [1, 2, 3] }
          ]
        }
        """)
        XCTAssertEqual(manifest.releases.count, 1)
    }

    /// Everything but version and headline is optional — a note with no video is
    /// a perfectly good note.
    func testAReleaseWithNoVideoOrHighlightsStillDecodes() throws {
        let manifest = try decode("""
        { "schemaVersion": 1, "releases": [ { "version": "1.1.0", "headline": "Hello" } ] }
        """)
        let release = try XCTUnwrap(manifest.releases.first)
        XCTAssertFalse(release.hasVideo)
        XCTAssertNil(release.posterURL)
        XCTAssertTrue(release.highlights.isEmpty)
    }

    /// One bad entry must not cost the user the whole surface.
    func testAMalformedReleaseIsDroppedWithoutTakingTheOthers() throws {
        let manifest = try decode("""
        {
          "schemaVersion": 1,
          "releases": [
            { "version": "1.1.0", "headline": "Good" },
            { "headline": "No version at all" },
            { "version": "1.2.0", "headline": "Also good" }
          ]
        }
        """)
        XCTAssertEqual(manifest.releases.map(\.version), ["1.1.0", "1.2.0"])
    }

    func testAReleaseWithAnUnparseableVersionIsDropped() throws {
        let manifest = try decode("""
        {
          "schemaVersion": 1,
          "releases": [
            { "version": "banana", "headline": "Nope" },
            { "version": "1.2.0", "headline": "Yes" }
          ]
        }
        """)
        XCTAssertEqual(manifest.releases.map(\.version), ["1.2.0"])
    }

    /// A release stamped with a schema this build doesn't understand is skipped
    /// rather than rendered half-right or crashed on.
    func testAReleaseFromANewerSchemaIsSkipped() throws {
        let manifest = try decode("""
        {
          "schemaVersion": 1,
          "releases": [
            { "version": "1.1.0", "headline": "Renderable" },
            { "version": "1.2.0", "headline": "From the future", "schemaVersion": 99 }
          ]
        }
        """)
        XCTAssertEqual(manifest.releases.map(\.version), ["1.1.0"])
    }

    func testAWholeManifestFromANewerSchemaYieldsNothingRenderable() throws {
        let manifest = try decode("""
        { "schemaVersion": 99, "releases": [ { "version": "1.1.0", "headline": "Future" } ] }
        """)
        XCTAssertTrue(manifest.releases.isEmpty)
    }

    func testMalformedJSONThrowsRatherThanCrashing() {
        XCTAssertThrowsError(try decode("{ not json at all "))
    }

    func testAnEmptyManifestDecodesToNoReleases() throws {
        XCTAssertTrue(try decode("{}").releases.isEmpty)
        XCTAssertTrue(try decode("{ \"schemaVersion\": 1, \"releases\": [] }").releases.isEmpty)
    }

    /// A `file://` URL in a remote manifest would be handed straight to
    /// AVPlayer, so only http(s) survives decoding.
    func testANonWebVideoURLIsRejected() throws {
        let manifest = try decode("""
        {
          "schemaVersion": 1,
          "releases": [
            { "version": "1.1.0", "headline": "Hi", "videoURL": "file:///etc/passwd" }
          ]
        }
        """)
        XCTAssertFalse(try XCTUnwrap(manifest.releases.first).hasVideo)
    }

    func testReleasesAreSortedAscendingWhateverOrderTheyArrivedIn() {
        let manifest = WhatsNewManifest(releases: [
            WhatsNewRelease(version: "1.10.0", headline: "c"),
            WhatsNewRelease(version: "1.2.0", headline: "a"),
            WhatsNewRelease(version: "1.9.0", headline: "b")
        ])
        XCTAssertEqual(manifest.releases.map(\.version), ["1.2.0", "1.9.0", "1.10.0"])
    }

    // MARK: - Picking the release to show

    private var threeReleases: WhatsNewManifest {
        WhatsNewManifest(releases: [
            WhatsNewRelease(version: "1.0.0", headline: "one"),
            WhatsNewRelease(version: "1.1.0", headline: "two"),
            WhatsNewRelease(version: "1.2.0", headline: "three")
        ])
    }

    func testTheUpgradeNoteIsTheNewestOneInRange() {
        let release = threeReleases.release(
            upgradingTo: SemanticVersion("1.2.0")!,
            from: SemanticVersion("1.0.0")!
        )
        XCTAssertEqual(release?.version, "1.2.0")
    }

    /// Skipping a version must not skip the note — someone going 1.0.0 → 1.2.0
    /// still gets the newest thing published in between.
    func testSkippingAVersionStillYieldsANote() {
        let manifest = WhatsNewManifest(releases: [
            WhatsNewRelease(version: "1.1.0", headline: "two")
        ])
        let release = manifest.release(
            upgradingTo: SemanticVersion("1.2.0")!,
            from: SemanticVersion("1.0.0")!
        )
        XCTAssertEqual(release?.version, "1.1.0")
    }

    /// A note published for a version newer than the one running is not ours yet.
    func testAReleaseNewerThanTheRunningBuildIsNotShown() {
        let release = threeReleases.release(
            upgradingTo: SemanticVersion("1.1.0")!,
            from: SemanticVersion("1.0.0")!
        )
        XCTAssertEqual(release?.version, "1.1.0")
    }

    func testNothingNewerThanLastSeenMeansNoNote() {
        let release = threeReleases.release(
            upgradingTo: SemanticVersion("1.2.0")!,
            from: SemanticVersion("1.2.0")!
        )
        XCTAssertNil(release)
    }

    func testTheManualEntryPointFallsBackToTheNewestKnownNote() {
        XCTAssertEqual(threeReleases.latestRelease(notNewerThan: nil)?.version, "1.2.0")
        XCTAssertEqual(
            threeReleases.latestRelease(notNewerThan: SemanticVersion("1.1.0")!)?.version,
            "1.1.0"
        )
    }
}

/// The whole flow, driven with a stub fetcher and an in-memory defaults suite —
/// no AppKit, no network.
@MainActor
final class WhatsNewControllerTests: XCTestCase {
    /// Never touches the real network; records whether it was asked at all, so
    /// "the gate short-circuited before fetching" is directly assertable.
    private final class StubFetcher: WhatsNewFetching, @unchecked Sendable {
        private let result: Result<WhatsNewManifest, Error>
        private(set) var fetchCount = 0

        init(_ result: Result<WhatsNewManifest, Error>) { self.result = result }

        func fetch() async throws -> WhatsNewManifest {
            fetchCount += 1
            return try result.get()
        }
    }

    private struct Offline: Error {}

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WhatsNewControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeController(
        currentVersion: String,
        lastSeen: String?,
        fetcher: StubFetcher,
        shown: @escaping (WhatsNewRelease) -> Void = { _ in }
    ) -> WhatsNewController {
        if let lastSeen {
            defaults.set(lastSeen, forKey: WhatsNewStore.defaultsKey)
        }
        return WhatsNewController(
            currentVersion: currentVersion,
            store: WhatsNewStore(defaults: defaults),
            fetcher: fetcher,
            presenter: shown
        )
    }

    private var oneNote: WhatsNewManifest {
        WhatsNewManifest(releases: [
            WhatsNewRelease(version: "1.1.0", headline: "Voice notes, everywhere")
        ])
    }

    func testAnUpgradeShowsTheNoteAndRecordsTheVersion() async {
        var shown: [String] = []
        let fetcher = StubFetcher(.success(oneNote))
        let controller = makeController(
            currentVersion: "1.1.0",
            lastSeen: "1.0.0",
            fetcher: fetcher
        ) { shown.append($0.version) }

        let release = await controller.resolveAndPresent(force: false)

        XCTAssertEqual(release?.version, "1.1.0")
        XCTAssertEqual(shown, ["1.1.0"])
        XCTAssertEqual(defaults.string(forKey: WhatsNewStore.defaultsKey), "1.1.0")
    }

    /// The first-install rule, end to end: nothing shown, version recorded, and
    /// — because the gate answers before the fetch — no network touched at all.
    func testAFirstInstallShowsNothingRecordsTheVersionAndNeverFetches() async {
        var shown: [String] = []
        let fetcher = StubFetcher(.success(oneNote))
        let controller = makeController(
            currentVersion: "1.1.0",
            lastSeen: nil,
            fetcher: fetcher
        ) { shown.append($0.version) }

        let release = await controller.resolveAndPresent(force: false)

        XCTAssertNil(release)
        XCTAssertTrue(shown.isEmpty)
        XCTAssertEqual(fetcher.fetchCount, 0)
        XCTAssertEqual(defaults.string(forKey: WhatsNewStore.defaultsKey), "1.1.0")
    }

    func testARelaunchOnTheSameVersionShowsNothing() async {
        var shown: [String] = []
        let fetcher = StubFetcher(.success(oneNote))
        let controller = makeController(
            currentVersion: "1.1.0",
            lastSeen: "1.1.0",
            fetcher: fetcher
        ) { shown.append($0.version) }

        let release = await controller.resolveAndPresent(force: false)

        XCTAssertNil(release)
        XCTAssertTrue(shown.isEmpty)
        XCTAssertEqual(fetcher.fetchCount, 0)
    }

    /// The rule that stops a launch on a plane from burning the release: a
    /// failed fetch must leave `lastSeenVersion` exactly as it was, so the next
    /// online launch still shows the note.
    func testAFailedFetchShowsNothingAndDoesNotBurnTheRelease() async {
        var shown: [String] = []
        let fetcher = StubFetcher(.failure(Offline()))
        let controller = makeController(
            currentVersion: "1.1.0",
            lastSeen: "1.0.0",
            fetcher: fetcher
        ) { shown.append($0.version) }

        let release = await controller.resolveAndPresent(force: false)

        XCTAssertNil(release)
        XCTAssertTrue(shown.isEmpty)
        XCTAssertEqual(defaults.string(forKey: WhatsNewStore.defaultsKey), "1.0.0")
    }

    /// Same reasoning for a manifest that fetched fine but has nothing to say
    /// about this upgrade.
    func testNoMatchingReleaseShowsNothingAndDoesNotBurnTheRelease() async {
        let fetcher = StubFetcher(.success(WhatsNewManifest(releases: [])))
        let controller = makeController(currentVersion: "1.1.0", lastSeen: "1.0.0", fetcher: fetcher)

        let release = await controller.resolveAndPresent(force: false)

        XCTAssertNil(release)
        XCTAssertEqual(defaults.string(forKey: WhatsNewStore.defaultsKey), "1.0.0")
    }

    /// The manual entry point has to work on a version the user has already seen.
    func testForcingBypassesTheGate() async {
        var shown: [String] = []
        let fetcher = StubFetcher(.success(oneNote))
        let controller = makeController(
            currentVersion: "1.1.0",
            lastSeen: "1.1.0",
            fetcher: fetcher
        ) { shown.append($0.version) }

        let release = await controller.resolveAndPresent(force: true)

        XCTAssertEqual(release?.version, "1.1.0")
        XCTAssertEqual(shown, ["1.1.0"])
    }

    /// A note with no video must still reach the window — the highlights carry it.
    func testAReleaseWithNoVideoIsStillShown() async {
        var shown: [WhatsNewRelease] = []
        let manifest = WhatsNewManifest(releases: [
            WhatsNewRelease(
                version: "1.1.0",
                headline: "Quieter release",
                highlights: [WhatsNewHighlight(title: "A", body: "B", systemImage: "sparkles")]
            )
        ])
        let controller = makeController(
            currentVersion: "1.1.0",
            lastSeen: "1.0.0",
            fetcher: StubFetcher(.success(manifest))
        ) { shown.append($0) }

        _ = await controller.resolveAndPresent(force: false)

        XCTAssertEqual(shown.count, 1)
        XCTAssertFalse(shown.first?.hasVideo ?? true)
        XCTAssertEqual(shown.first?.highlights.count, 1)
    }

    /// The 1.10.0 > 1.9.0 case all the way through the controller.
    func testAnUpgradePastNineIsShown() async {
        var shown: [String] = []
        let manifest = WhatsNewManifest(releases: [
            WhatsNewRelease(version: "1.10.0", headline: "Ten")
        ])
        let controller = makeController(
            currentVersion: "1.10.0",
            lastSeen: "1.9.0",
            fetcher: StubFetcher(.success(manifest))
        ) { shown.append($0.version) }

        _ = await controller.resolveAndPresent(force: false)

        XCTAssertEqual(shown, ["1.10.0"])
    }
}
