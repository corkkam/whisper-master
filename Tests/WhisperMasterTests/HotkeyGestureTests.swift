import XCTest
@testable import WhisperMaster

/// The push-to-talk gesture machine. Pure and clock-injected, so every timing
/// case here is exact rather than flaky.
final class HotkeyGestureTests: XCTestCase {
    private func makeGesture() -> HotkeyGesture {
        HotkeyGesture(tapMaxHold: 0.35, doubleTapWindow: 0.4)
    }

    // MARK: - Hold (the default push-to-talk)

    func testHoldStartsOnPressAndStopsOnRelease() {
        var g = makeGesture()
        XCTAssertEqual(g.press(now: 1.0), .start)
        XCTAssertNil(g.release(now: 1.2), "a sub-tap release must not stop immediately — it may be a latch")
        XCTAssertEqual(g.press(now: 10.0), .start)
        XCTAssertEqual(g.release(now: 13.0), .stop, "a real hold ends the moment the key comes up")
    }

    func testRecordingBeginsOnTheKeyDownNotAfterAWaitAndSee() {
        var g = makeGesture()
        // The whole point: no double-tap detection delay on the *start*.
        XCTAssertEqual(g.press(now: 5.0), .start)
    }

    // MARK: - Lone tap

    func testLoneTapStopsWhenTheDoubleTapWindowExpires() {
        var g = makeGesture()
        XCTAssertEqual(g.press(now: 1.0), .start)
        XCTAssertNil(g.release(now: 1.1))
        XCTAssertNil(g.flush(now: 1.4), "still inside the window")
        XCTAssertEqual(g.flush(now: 1.5), .stop)
        XCTAssertFalse(g.isHandsFree)
    }

    func testALoneTapArmsTheFlushDeadline() {
        var g = makeGesture()
        _ = g.press(now: 1.0)
        _ = g.release(now: 1.1)
        XCTAssertEqual(g.pendingStopAt, 1.5)
    }

    // MARK: - Double-tap latch

    func testDoubleTapLatchesHandsFreeWithoutStoppingTheRecording() {
        var g = makeGesture()
        XCTAssertEqual(g.press(now: 1.0), .start)
        XCTAssertNil(g.release(now: 1.1))
        XCTAssertEqual(g.press(now: 1.3), .handsFreeOn, "second tap inside the window latches")
        XCTAssertNil(g.release(now: 1.4), "the latching tap's release must not stop it")
        XCTAssertTrue(g.isHandsFree)
        XCTAssertNil(g.pendingStopAt, "the deferred stop is cancelled by the latch")
        XCTAssertNil(g.flush(now: 9.0), "and no stray timer can end the session later")
    }

    func testSecondDoubleTapEndsTheHandsFreeSession() {
        var g = makeGesture()
        _ = g.press(now: 1.0)
        _ = g.release(now: 1.1)
        _ = g.press(now: 1.3)
        _ = g.release(now: 1.4)
        XCTAssertTrue(g.isHandsFree)

        // Some time later, two more taps.
        XCTAssertNil(g.press(now: 20.0), "a press while latched starts nothing")
        XCTAssertNil(g.release(now: 20.1))
        XCTAssertEqual(g.press(now: 20.3), .stop, "the closing tap ends it on the press")
        XCTAssertNil(g.release(now: 20.4))
        XCTAssertFalse(g.isHandsFree)
    }

    func testLoneTapWhileHandsFreeChangesNothing() {
        var g = makeGesture()
        _ = g.press(now: 1.0); _ = g.release(now: 1.1)
        _ = g.press(now: 1.3); _ = g.release(now: 1.4)
        XCTAssertTrue(g.isHandsFree)

        XCTAssertNil(g.press(now: 5.0))
        XCTAssertNil(g.release(now: 5.1))
        XCTAssertNil(g.flush(now: 6.0), "a single stray tap must not end a hands-free session")
        XCTAssertTrue(g.isHandsFree)
    }

    func testTapsTooFarApartAreTwoSeparateHoldsNotALatch() {
        var g = makeGesture()
        XCTAssertEqual(g.press(now: 1.0), .start)
        XCTAssertNil(g.release(now: 1.1))
        XCTAssertEqual(g.flush(now: 1.5), .stop)
        XCTAssertEqual(g.press(now: 2.0), .start, "outside the window this is a fresh session")
        XCTAssertFalse(g.isHandsFree)
    }

    func testHoldWhileHandsFreeIsAnEscapeHatch() {
        var g = makeGesture()
        _ = g.press(now: 1.0); _ = g.release(now: 1.1)
        _ = g.press(now: 1.3); _ = g.release(now: 1.4)
        XCTAssertTrue(g.isHandsFree)

        XCTAssertNil(g.press(now: 30.0))
        XCTAssertEqual(g.release(now: 31.0), .stop, "a deliberate hold ends it for anyone who misses the double-tap")
        XCTAssertFalse(g.isHandsFree)
    }

    // MARK: - Reset

    func testResetDropsTheLatchAndAnyPendingStop() {
        var g = makeGesture()
        _ = g.press(now: 1.0); _ = g.release(now: 1.1)
        _ = g.press(now: 1.3); _ = g.release(now: 1.4)
        XCTAssertTrue(g.isHandsFree)

        g.reset()
        XCTAssertFalse(g.isHandsFree)
        XCTAssertNil(g.pendingStopAt)
        // The next press is an ordinary new session, not a "stop".
        XCTAssertEqual(g.press(now: 2.0), .start)
    }

    func testReleaseWithoutAPressIsIgnored() {
        var g = makeGesture()
        XCTAssertNil(g.release(now: 1.0), "key already down when the monitor was installed")
    }

    // MARK: - Key identity

    func testFnIsTheDefaultAndCarriesTheSecondaryFnBit() {
        XCTAssertEqual(HotkeyManager.HotkeyOption.allCases.first, .fn)
        XCTAssertEqual(HotkeyManager.HotkeyOption.fn.keyCode, 63)
        XCTAssertEqual(HotkeyManager.HotkeyOption.fn.modifierBit, 0x0080_0000)
    }

    func testEveryOptionHasADistinctKeyCode() {
        let codes = HotkeyManager.HotkeyOption.allCases.map(\.keyCode)
        XCTAssertEqual(Set(codes).count, codes.count)
    }
}
