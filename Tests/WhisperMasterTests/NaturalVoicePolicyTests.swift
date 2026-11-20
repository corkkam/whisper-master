import XCTest

@testable import WhisperMaster

/// The natural voice is the default, so it fetches and warms itself. Each rule here
/// is one that went wrong, or would have, on every install.
final class NaturalVoicePolicyTests: XCTestCase {

    // MARK: - The one automatic fetch

    func testTheDefaultVoiceFetchesItselfOnce() {
        XCTAssertTrue(NaturalVoicePolicy.shouldAutoInstall(
            alreadyTried: false, installed: false, downloading: false))
        XCTAssertFalse(NaturalVoicePolicy.shouldAutoInstall(
            alreadyTried: true, installed: false, downloading: false),
            "a failed fetch is retried from Settings, never from the next answer")
    }

    func testNothingIsFetchedWhenItIsAlreadyHereOrOnItsWay() {
        XCTAssertFalse(NaturalVoicePolicy.shouldAutoInstall(
            alreadyTried: false, installed: true, downloading: false))
        XCTAssertFalse(NaturalVoicePolicy.shouldAutoInstall(
            alreadyTried: false, installed: false, downloading: true))
    }

    // MARK: - Warming on the tick

    /// The bug: warming on every tick reloaded the models half a second after their
    /// idle unload, so they never unloaded.
    func testATickWithTheNaturalVoiceAlreadyChosenWarmsNothing() {
        XCTAssertFalse(NaturalVoicePolicy.shouldWarmOnTick(previous: .natural, current: .natural))
    }

    func testSwitchingToTheNaturalVoiceWarmsIt() {
        XCTAssertTrue(NaturalVoicePolicy.shouldWarmOnTick(previous: .system, current: .natural))
        XCTAssertTrue(NaturalVoicePolicy.shouldWarmOnTick(previous: nil, current: .natural),
                      "the first tick that sees it chosen")
    }

    func testTheSystemVoiceNeverWarmsTheNaturalOne() {
        XCTAssertFalse(NaturalVoicePolicy.shouldWarmOnTick(previous: nil, current: .system))
        XCTAssertFalse(NaturalVoicePolicy.shouldWarmOnTick(previous: .natural, current: .system))
    }

    // MARK: - After a failed load

    func testALoadThatNeverFailedMayStart() {
        XCTAssertTrue(NaturalVoicePolicy.mayLoad(lastFailure: nil, now: Date(), force: false))
    }

    func testAFailedLoadIsLeftAloneForTheBackoff() {
        let failed = Date(timeIntervalSince1970: 1_000_000)
        let soon = failed.addingTimeInterval(NaturalVoicePolicy.loadRetryBackoff - 1)
        let later = failed.addingTimeInterval(NaturalVoicePolicy.loadRetryBackoff)
        XCTAssertFalse(NaturalVoicePolicy.mayLoad(lastFailure: failed, now: soon, force: false))
        XCTAssertTrue(NaturalVoicePolicy.mayLoad(lastFailure: failed, now: later, force: false))
    }

    /// The Settings retry is the user asking, so it does not wait.
    func testAForcedLoadSkipsTheBackoff() {
        let failed = Date()
        XCTAssertTrue(NaturalVoicePolicy.mayLoad(lastFailure: failed, now: failed, force: true))
    }
}
