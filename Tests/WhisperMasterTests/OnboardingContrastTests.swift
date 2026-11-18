import AppKit
import SwiftUI
import XCTest

@testable import WhisperMaster

/// Every onboarding foreground over the band's black, at WCAG ratios: text at
/// 4.5 to 1 or more, capsules and the focus ring at 3 to 1 or more.
final class OnboardingContrastTests: XCTestCase {
    private typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

    private func rgba(_ color: Color) -> RGBA {
        let ns = NSColor(color).usingColorSpace(.sRGB)!
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }

    /// `top` drawn over an opaque `bottom`.
    private func over(_ top: RGBA, _ bottom: RGBA) -> RGBA {
        let a = top.a
        return (top.r * a + bottom.r * (1 - a), top.g * a + bottom.g * (1 - a), top.b * a + bottom.b * (1 - a), 1)
    }

    private func luminance(_ c: RGBA) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    private func ratio(_ foreground: Color, on background: RGBA) -> Double {
        let lf = luminance(over(rgba(foreground), background))
        let lb = luminance(background)
        return (max(lf, lb) + 0.05) / (min(lf, lb) + 0.05)
    }

    private var surface: RGBA { rgba(Theme.Notch.surface) }

    func testTextTokensReadOnTheBand() {
        for (name, color) in [
            ("text", Theme.Notch.text), ("textSecondary", Theme.Notch.textSecondary),
            ("textTertiary", Theme.Notch.textTertiary),
        ] {
            XCTAssertGreaterThanOrEqual(ratio(color, on: surface), 4.5, name)
        }
        XCTAssertEqual(ratio(Theme.Notch.textTertiary, on: surface), 6.5, accuracy: 0.2)
    }

    func testCapsulesAndTheFocusRingReadOnTheBand() {
        for (name, color) in [
            ("futureStep", Theme.Notch.futureStep), ("success", Theme.Notch.success),
            ("accent", Theme.Notch.accent), ("focus ring", Theme.Notch.text),
        ] {
            XCTAssertGreaterThanOrEqual(ratio(color, on: surface), 3, name)
        }
    }

    /// The old future-capsule colour is why `futureStep` exists.
    func testHairlineIsTooFaintForACapsule() {
        XCTAssertLessThan(ratio(Theme.Notch.hairline, on: surface), 3)
    }

    /// The top-bar line sits at the band's top edge, where the glass sheen
    /// (white at 0.07) lies over the black.
    func testTertiaryTextReadsUnderTheGlassSheen() {
        let sheen = over(rgba(Color.white.opacity(0.07)), surface)
        XCTAssertGreaterThanOrEqual(ratio(Theme.Notch.textTertiary, on: sheen), 4.5)
    }
}
