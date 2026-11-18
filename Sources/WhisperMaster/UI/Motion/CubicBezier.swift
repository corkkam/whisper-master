import SwiftUI

/// A CSS-style `cubic-bezier(x1, y1, x2, y2)` easing curve, solved in plain Swift.
///
/// `UnitCurve` would do this, but it needs macOS 15 and the target is 14. The
/// onboarding frames are pure functions of time (so `WM_SNAPSHOT` can render any
/// instant), which means they need the curve as a number, not as an `Animation`.
/// The house curve's four numbers live here once; `Theme.Motion` builds its
/// animations from them.
struct CubicBezier: Equatable, Sendable {
    let x1, y1, x2, y2: Double

    /// The house curve: fast out, long soft settle, no overshoot.
    static let settle = CubicBezier(x1: 0.16, y1: 1, x2: 0.3, y2: 1)
    /// The pure fade curve. Close to, but not the same as, `Theme.Motion.fade`,
    /// which stays `easeOut`.
    static let fade = CubicBezier(x1: 0, y1: 0, x2: 0.58, y2: 1)

    /// Eased value at `progress`, clamped to 0...1.
    func value(at progress: Double) -> Double {
        let x = min(1, max(0, progress))
        if x == 0 || x == 1 { return x }
        return Self.sample(parameter(forX: x), y1, y2)
    }

    /// The same curve as a SwiftUI animation.
    func animation(duration: Double) -> Animation {
        .timingCurve(x1, y1, x2, y2, duration: duration)
    }

    /// One axis of the curve, with its end points fixed at 0 and 1.
    private static func sample(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    private static func slope(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
    }

    /// The curve parameter whose x is `x`. Newton first, bisection when Newton
    /// stalls on a flat stretch or leaves 0...1.
    private func parameter(forX x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let error = Self.sample(t, x1, x2) - x
            if abs(error) < 1e-9 { return t }
            let d = Self.slope(t, x1, x2)
            guard abs(d) > 1e-9 else { break }
            let next = t - error / d
            guard (0...1).contains(next) else { break }
            t = next
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 {
            t = (lo + hi) / 2
            if Self.sample(t, x1, x2) < x { lo = t } else { hi = t }
        }
        return (lo + hi) / 2
    }
}
