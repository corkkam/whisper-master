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
}
