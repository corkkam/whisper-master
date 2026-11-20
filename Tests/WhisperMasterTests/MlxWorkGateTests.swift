import XCTest

@testable import WhisperMaster

/// The quit hold: `applicationShouldTerminate` waits on `drain` so MLX is not
/// destroyed under a running generation. Each test uses its own gate; the shared
/// one belongs to the app.
final class MlxWorkGateTests: XCTestCase {
    func testDrainReturnsAtOnceWhenNothingRuns() async {
        let gate = MlxWorkGate()
        let drained = await gate.drain(timeout: 0.5)
        XCTAssertTrue(drained)
    }

    func testDrainWaitsForRunningWorkToLeave() async {
        let gate = MlxWorkGate()
        gate.enter()
        let started = Date()
        Task.detached {
            try? await Task.sleep(nanoseconds: 100_000_000)
            gate.leave()
        }
        let drained = await gate.drain(timeout: 2)
        XCTAssertTrue(drained)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.09)
        XCTAssertEqual(gate.inFlight, 0)
    }

    // A model load cannot be interrupted, so the hold is bounded: the app quits
    // rather than hangs on a load that never returns.
    func testDrainGivesUpAfterTheTimeout() async {
        let gate = MlxWorkGate()
        gate.enter()
        let drained = await gate.drain(timeout: 0.1)
        XCTAssertFalse(drained)
        XCTAssertEqual(gate.inFlight, 1)
    }

    // After a quit begins no new work may start, or a generation begun after
    // `drain` saw zero would still be running when the app exits.
    func testNoWorkStartsOnceAQuitHasBegun() async {
        let gate = MlxWorkGate()
        XCTAssertTrue(gate.enter())
        gate.beginQuit()
        XCTAssertFalse(gate.enter())
        XCTAssertEqual(gate.inFlight, 1, "a refused entry is not counted")
        gate.leave()
        let drained = await gate.drain(timeout: 0.5)
        XCTAssertTrue(drained)
    }

    // The token loops read this to stop at the next token.
    func testBeginQuitIsSeenByEveryReader() {
        let gate = MlxWorkGate()
        XCTAssertFalse(gate.isQuitting)
        gate.beginQuit()
        XCTAssertTrue(gate.isQuitting)
    }

    // Idle app: the delegate answers `.terminateNow` and never replies later.
    func testHoldQuitReturnsFalseWhenIdleAndStillBlocksNewWork() {
        let gate = MlxWorkGate()
        let finished = expectation(description: "finish must not run")
        finished.isInverted = true
        XCTAssertFalse(gate.holdQuit(timeout: 0.1, grace: 0) { finished.fulfill() })
        XCTAssertTrue(gate.isQuitting)
        XCTAssertFalse(gate.enter())
        wait(for: [finished], timeout: 0.3)
    }

    // Busy app: the quit is held, and `finish` runs once after the work leaves.
    func testHoldQuitFinishesOnceAfterWorkLeaves() async {
        let gate = MlxWorkGate()
        gate.enter()
        let finished = expectation(description: "finish")
        let held = gate.holdQuit(timeout: 2, grace: 0) { finished.fulfill() }
        XCTAssertTrue(held)
        gate.leave()
        await fulfillment(of: [finished], timeout: 2)
    }

    // A load that never returns must not hang a Sparkle quit-to-install:
    // `finish` still runs when the timeout passes.
    func testHoldQuitFinishesOnTimeoutWhenWorkNeverLeaves() async {
        let gate = MlxWorkGate()
        gate.enter()
        let finished = expectation(description: "finish")
        XCTAssertTrue(gate.holdQuit(timeout: 0.1, grace: 0) { finished.fulfill() })
        await fulfillment(of: [finished], timeout: 2)
    }

    // A stray leave (after a timed-out drain) cannot push the count negative and
    // make later work look absent.
    func testLeaveNeverUnderflows() {
        let gate = MlxWorkGate()
        gate.leave()
        XCTAssertEqual(gate.inFlight, 0)
    }
}
