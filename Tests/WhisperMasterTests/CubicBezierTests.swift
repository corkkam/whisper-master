import SwiftUI
import XCTest

@testable import WhisperMaster

/// The house curve as a number. Onboarding frames are pure functions of time, so
/// they read the curve here rather than from a SwiftUI `Animation`.
final class CubicBezierTests: XCTestCase {
    private let curves = [CubicBezier.settle, CubicBezier.fade]

    func testEndsAreExact() {
        for curve in curves {
            XCTAssertEqual(curve.value(at: 0), 0)
            XCTAssertEqual(curve.value(at: 1), 1)
        }
    }

    func testMonotonicWithNoOvershoot() {
        for curve in curves {
            var last = 0.0
            for step in 0...1000 {
                let value = curve.value(at: Double(step) / 1000)
                XCTAssertGreaterThanOrEqual(value, last - 1e-12, "\(curve) dips at \(step)")
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
                last = value
            }
        }
    }

    func testProgressOutsideTheUnitIsClamped() {
        XCTAssertEqual(CubicBezier.settle.value(at: -3), 0)
        XCTAssertEqual(CubicBezier.settle.value(at: 7), 1)
    }

    /// `settle` decelerates hard: most of the move is done early.
    func testSettleIsFastOutSoftIn() {
        XCTAssertGreaterThan(CubicBezier.settle.value(at: 0.25), 0.7)
        XCTAssertLessThan(CubicBezier.fade.value(at: 0.25), CubicBezier.settle.value(at: 0.25))
    }

    func testSettleHoldsTheHouseNumbersAndDuration() {
        XCTAssertEqual(CubicBezier.settle, CubicBezier(x1: 0.16, y1: 1, x2: 0.3, y2: 1))
        XCTAssertEqual(CubicBezier.fade, CubicBezier(x1: 0, y1: 0, x2: 0.58, y2: 1))
        XCTAssertEqual(Theme.Motion.settleDuration, 0.42)
    }

    /// `Theme.Motion` is built from the same four numbers, at its two durations.
    func testThemeMotionIsBuiltFromTheCurve() {
        let c = CubicBezier.settle
        XCTAssertEqual(Theme.Motion.settle, Animation.timingCurve(c.x1, c.y1, c.x2, c.y2, duration: 0.42))
        XCTAssertEqual(Theme.Motion.quick, Animation.timingCurve(c.x1, c.y1, c.x2, c.y2, duration: 0.25))
    }
}
