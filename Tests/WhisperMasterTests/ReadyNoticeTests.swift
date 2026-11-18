import XCTest

@testable import WhisperMaster

/// The Ready notice: the one line that says the speech files finished after
/// setup closed. Locked here are its place at the bottom of the band's ladder
/// (`NotchActivity.resolve` mirrors `DictationStatusView`'s render order) and
/// its paused clock, whose hold writes `AppState` once, when it ends.
@MainActor
final class ReadyNoticeTests: XCTestCase {
    private func stateWithNotice() -> AppState {
        let state = AppState()
        state.phase = .idle
        state.readyNoticeAt = Date()
        return state
    }

    // MARK: Ladder

    func testShowsWhenNothingElseHoldsTheBand() {
        let state = stateWithNotice()
        XCTAssertEqual(NotchActivity.resolve(from: state), .readyNotice)
        XCTAssertTrue(state.canShowReadyNotice)
        // Not in `notchIsOccupied`: the hover panel still opens over it.
        XCTAssertFalse(state.notchIsOccupied)
    }

    func testIsTheLowestRungBelowTheDeliveredBeat() {
        let state = stateWithNotice()
        state.deliveredAt = Date()
        XCTAssertEqual(NotchActivity.resolve(from: state), .delivered)
        XCTAssertFalse(state.canShowReadyNotice)
    }

    func testLiveWorkOutranksIt() {
        let state = stateWithNotice()
        state.phase = .recording
        XCTAssertEqual(NotchActivity.resolve(from: state), .listening)
        XCTAssertFalse(state.canShowReadyNotice)

        state.phase = .idle
        state.isPolishing = true
        XCTAssertEqual(NotchActivity.resolve(from: state), .polishing)
        XCTAssertFalse(state.canShowReadyNotice)
    }

    func testABannerHoldsIt() {
        let state = stateWithNotice()
        state.activeReminder = "Dictate something?"
        XCTAssertFalse(state.canShowReadyNotice)
        state.activeReminder = nil
        state.undeliveredText = "words"
        state.undeliveredTranscriptAt = Date()
        XCTAssertFalse(state.canShowReadyNotice)
    }

    func testNoNoticeResolvesIdle() {
        let state = AppState()
        state.phase = .idle
        XCTAssertEqual(NotchActivity.resolve(from: state), .idle)
        XCTAssertFalse(state.shouldShowReadyNotice)
    }

    func testIsMatteWithNoStateWord() {
        XCTAssertNil(NotchActivity.readyNotice.accent)
        XCTAssertEqual(NotchActivity.readyNotice.glowStrength, 0)
        XCTAssertNil(NotchActivity.readyNotice.orbMode)
        XCTAssertEqual(NotchActivity.readyNotice.label(holdToTalk: true), "")
    }

    // MARK: Paused clock

    /// Held for 3 s across several ticks: nothing is written until the hold
    /// ends, and then the shown-at time moves forward by exactly 3 s.
    func testAHoldIsWrittenOnceWhenItEnds() {
        let shownAt = Date(timeIntervalSinceReferenceDate: 100)
        var hold = ReadyNoticeHold()
        hold.hold(at: Date(timeIntervalSinceReferenceDate: 101))
        hold.hold(at: Date(timeIntervalSinceReferenceDate: 102))
        hold.hold(at: Date(timeIntervalSinceReferenceDate: 103))
        XCTAssertEqual(hold.heldAt, Date(timeIntervalSinceReferenceDate: 101))

        let moved = hold.resume(shownAt: shownAt, at: Date(timeIntervalSinceReferenceDate: 104))
        XCTAssertEqual(moved, Date(timeIntervalSinceReferenceDate: 103))
        XCTAssertNil(hold.heldAt)
    }

    /// The tick calls resume on every free tick; with no hold it writes nothing.
    func testResumeWithoutAHoldWritesNothing() {
        var hold = ReadyNoticeHold()
        XCTAssertNil(hold.resume(shownAt: Date(), at: Date()))
    }
}
