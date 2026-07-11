import XCTest

@testable import WhisperMaster

final class LevelEnvelopeTests: XCTestCase {
    func testStartsAtZero() {
        let env = LevelEnvelope()
        XCTAssertEqual(env.current, 0)
    }

    func testRisesTowardTargetWithoutOvershooting() {
        var env = LevelEnvelope(attack: 0.5, decay: 0.1)
        let first = env.step(target: 1.0)
        XCTAssertEqual(first, 0.5, accuracy: 0.0001)   // halfway on the first attack step
        let second = env.step(target: 1.0)
        XCTAssertGreaterThan(second, first)
        XCTAssertLessThan(second, 1.0)                 // never overshoots the target
    }

    func testDecayIsSlowerThanAttack() {
        var attackEnv = LevelEnvelope(attack: 0.5, decay: 0.1)
        var decayEnv = LevelEnvelope(attack: 0.5, decay: 0.1)
        // Rise both to the same level.
        attackEnv.step(target: 1.0)
        decayEnv.step(target: 1.0)
        let rose = attackEnv.step(target: 1.0)         // keep rising toward 1
        let fell = decayEnv.step(target: 0.0)          // start falling toward 0
        // The gap covered while rising (fast attack) exceeds the gap covered
        // while falling (slow decay) over one step.
        XCTAssertGreaterThan(rose - 0.5, 0.5 - fell)
    }

    func testSettlesFlatAtZero() {
        var env = LevelEnvelope(attack: 0.6, decay: 0.4)
        env.step(target: 1.0)
        for _ in 0..<200 { env.step(target: 0.0) }
        XCTAssertEqual(env.current, 0, "should clamp to a flat zero, not leave a residual")
    }

    func testNegativeTargetTreatedAsZero() {
        var env = LevelEnvelope()
        env.step(target: 0.5)
        let out = env.step(target: -5.0)
        XCTAssertLessThan(out, 0.5)
        XCTAssertGreaterThanOrEqual(out, 0)
    }

    func testResetReturnsToZero() {
        var env = LevelEnvelope()
        env.step(target: 1.0)
        env.reset()
        XCTAssertEqual(env.current, 0)
    }
}
