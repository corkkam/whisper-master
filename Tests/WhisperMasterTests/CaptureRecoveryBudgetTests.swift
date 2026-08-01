import XCTest

@testable import WhisperMaster

/// The budget that stops a flapping audio route from turning mid-recording graph
/// recovery into an endless rebuild loop. Clock-injected, so the arithmetic is checked
/// here rather than by unplugging speakers.
final class CaptureRecoveryBudgetTests: XCTestCase {
    func testAllowsUpToTheLimitInsideTheWindow() {
        var budget = CaptureRecoveryBudget(limit: 3, window: 2)
        XCTAssertTrue(budget.allowAttempt(now: 0))
        XCTAssertTrue(budget.allowAttempt(now: 0.5))
        XCTAssertTrue(budget.allowAttempt(now: 1))
    }

    /// The whole point: past the limit it stops saying yes, so the caller abandons the
    /// session instead of rebuilding forever.
    func testRefusesPastTheLimit() {
        var budget = CaptureRecoveryBudget(limit: 3, window: 2)
        for step in 0..<3 { XCTAssertTrue(budget.allowAttempt(now: Double(step) * 0.1)) }
        XCTAssertFalse(budget.allowAttempt(now: 0.4))
        XCTAssertFalse(budget.allowAttempt(now: 0.5), "and it stays refused inside the window")
    }

    /// A route change long after the last burst is a new event, not a continuation —
    /// otherwise one bad afternoon would poison every later session.
    func testAFreshBurstStartsAfterTheWindowElapses() {
        var budget = CaptureRecoveryBudget(limit: 2, window: 2)
        XCTAssertTrue(budget.allowAttempt(now: 0))
        XCTAssertTrue(budget.allowAttempt(now: 0.1))
        XCTAssertFalse(budget.allowAttempt(now: 0.2))
        XCTAssertTrue(budget.allowAttempt(now: 10), "well past the window — a new burst")
        XCTAssertTrue(budget.allowAttempt(now: 10.1))
        XCTAssertFalse(budget.allowAttempt(now: 10.2))
    }

    /// The window is measured from the burst's first attempt, so a slow drip that stays
    /// inside it is still one burst.
    func testTheWindowIsMeasuredFromTheFirstAttemptNotTheLast() {
        var budget = CaptureRecoveryBudget(limit: 2, window: 2)
        XCTAssertTrue(budget.allowAttempt(now: 0))
        XCTAssertTrue(budget.allowAttempt(now: 1.5))
        XCTAssertFalse(budget.allowAttempt(now: 1.9))
    }

    func testResetGivesTheNextSessionAFullBudget() {
        var budget = CaptureRecoveryBudget(limit: 2, window: 2)
        XCTAssertTrue(budget.allowAttempt(now: 0))
        XCTAssertTrue(budget.allowAttempt(now: 0.1))
        XCTAssertFalse(budget.allowAttempt(now: 0.2))
        budget.reset()
        XCTAssertTrue(budget.allowAttempt(now: 0.3))
        XCTAssertTrue(budget.allowAttempt(now: 0.4))
    }
}
