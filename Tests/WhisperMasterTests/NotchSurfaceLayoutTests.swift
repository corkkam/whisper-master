import XCTest

@testable import WhisperMaster

/// How wide the black surface gets, and why the bar's width now follows its own
/// state word.
///
/// The bar's leading label lives in the **wing** beside the camera housing, and
/// `wideSideExtension` was a constant sized to the longest fixed caption
/// ("Dictating (hands-free)"). The assistant's captions carry a user-chosen
/// connector name, which has no bound — and a caption longer than the wing doesn't
/// truncate, it runs into the region the housing physically covers and its tail is
/// simply not on screen.
final class NotchSurfaceLayoutTests: XCTestCase {
    private let layout = NotchSurfaceLayout()
    /// A 14" MacBook Pro: notch ~200pt on a 1512pt display.
    private let geometry = NotchGeometry(notchWidth: 200, notchHeight: 37.5, screenWidth: 1512)

    func testAShortCaptionLeavesTheBarAtItsBaseWidth() {
        XCTAssertEqual(layout.wideWing(forStateLabel: "Dictating"), layout.wideSideExtension)
        XCTAssertEqual(
            layout.surfaceWidth(for: geometry, .wide, stateLabel: "Dictating"),
            layout.surfaceWidth(for: geometry, .wide))
    }

    /// The regression this exists for: a caption naming a long connection has to
    /// widen the band rather than disappear under the housing.
    func testALongConnectorCaptionWidensTheBar() {
        let long = "Checking Personal Google Calendar"
        XCTAssertGreaterThan(layout.wideWing(forStateLabel: long), layout.wideSideExtension)
        XCTAssertGreaterThan(
            layout.surfaceWidth(for: geometry, .wide, stateLabel: long),
            layout.surfaceWidth(for: geometry, .wide))
    }

    /// The wing has to actually clear the text it was measured for, or the growth
    /// buys nothing.
    func testTheGrownWingClearsTheLabelItWasMeasuredFor() {
        let long = "Checking Personal Google Calendar"
        let wing = layout.wideWing(forStateLabel: long)
        XCTAssertGreaterThanOrEqual(
            wing - NotchTranscriptRow.horizontalPadding,
            NotchTextMetrics.width(long))
    }

    /// Unbounded growth would clip against the panel and start swallowing menu-bar
    /// clicks either side of the notch, so the wing is capped.
    func testTheWingIsCapped() {
        let absurd = String(repeating: "Personal ", count: 40)
        XCTAssertEqual(layout.wideWing(forStateLabel: absurd), layout.maxStateLabelWing)
    }

    /// **The panel must fit the widest bar there can ever be.** It's sized once, at
    /// window creation, before any caption exists — size it to the base wing and the
    /// grown band is clipped by its own window, which would hide exactly the
    /// captions this feature adds.
    func testThePanelFitsTheWidestBarTheCaptionsCanProduce() {
        let panel = layout.panelSize(for: geometry).width
        let absurd = String(repeating: "Personal ", count: 40)
        XCTAssertGreaterThanOrEqual(
            panel, layout.surfaceWidth(for: geometry, .wide, stateLabel: absurd))
        XCTAssertGreaterThanOrEqual(
            panel, layout.surfaceWidth(for: geometry, .wide, stateLabel: "Checking Personal"))
    }

    /// The bar is still the one surface bounded by the display it's drawn on — a
    /// grown wing must not push it off a small screen.
    func testTheGrownBarStillFitsASmallDisplay() {
        let small = NotchGeometry(notchWidth: 180, notchHeight: 32, screenWidth: 640)
        let absurd = String(repeating: "Personal ", count: 40)
        XCTAssertLessThanOrEqual(
            layout.surfaceWidth(for: small, .wide, stateLabel: absurd),
            small.screenWidth - layout.wideScreenInset * 2)
    }

    /// Past the cap the label needs a ceiling of its own: the `HStack` alone only
    /// bounds it by the whole surface, whose middle is behind the housing.
    func testTheRowLabelIsBoundedByItsWing() {
        let wing = layout.wideWing(forStateLabel: "Checking Personal")
        XCTAssertLessThan(layout.rowLabelMaxWidth(for: geometry, wing: wing), wing)
    }

    /// Banners and the badge are unaffected — only the bar reads the caption.
    func testOnlyTheBarWidthRespondsToTheStateLabel() {
        for kind in [NotchSurfaceWidth.glyph, .banner] {
            XCTAssertEqual(
                layout.surfaceWidth(for: geometry, kind, stateLabel: "Checking Personal Calendar"),
                layout.surfaceWidth(for: geometry, kind))
        }
    }
}
