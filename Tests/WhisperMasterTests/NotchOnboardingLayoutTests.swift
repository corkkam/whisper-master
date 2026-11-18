import AppKit
import XCTest

@testable import WhisperMaster

/// The band is sized once, when its panel is made, so every state has to fit
/// the one depth. Copy gives way before depth: a body that does not fit two
/// lines shows its fallback.
final class NotchOnboardingLayoutTests: XCTestCase {
    private let layout = NotchOnboardingLayout()

    override func setUp() {
        super.setUp()
        XCTAssertTrue(BrandFontsForTests.register(), "the brand fonts did not register")
    }

    func testTheConstants() {
        XCTAssertEqual(layout.thickness, 264)
        XCTAssertEqual(layout.topConcaveRadius, 14)
        XCTAssertEqual(layout.bottomCornerRadius, 24)
        XCTAssertEqual(layout.topBarLineMaxWidth, 260)
        XCTAssertEqual(layout.stageWidth, 640)
        XCTAssertEqual(layout.stageDepth, 420)
        XCTAssertEqual(layout.stageBottomRadius, 40)
        XCTAssertEqual(layout.stageOrbDiameter, 150)
        XCTAssertEqual(layout.stageOrbCenterY, 172)
        XCTAssertEqual(layout.stageWordmarkY, 300)
        XCTAssertEqual(layout.stageTaglineY, 340)
    }

    /// Top padding, top bar, dots, gap, then half of the 62 pt orb.
    func testTheOrbCentreFollowsTheRowsAboveIt() {
        XCTAssertEqual(layout.orbCenterY, Theme.Space.md + 24 + 5 + Theme.Space.sm + 62 / 2)
    }

    func testThePanelGrowsWithTheBand() {
        let geometry = NotchGeometry(notchWidth: 208, notchHeight: 37.5, screenWidth: 1710)
        XCTAssertEqual(layout.panelSize(for: geometry).height, 37.5 + 264)
    }

    func testEveryStateFitsTheBandDepth() {
        let headlineFont = BrandFontsForTests.sans(19, .bold)
        let bodyFont = BrandFontsForTests.sans(13)
        let labelFont = BrandFontsForTests.sans(14, .semibold)
        let textWidth: CGFloat = 361
        let actionRow = BrandFontsForTests.lineHeight(labelFont) + 2 * 9
        let fixed = Theme.Space.md + 24 + 5 + Theme.Space.sm + 62 + Theme.Space.md + 3 + Theme.Space.lg
            + actionRow + Theme.Space.lg
        var deepest: CGFloat = 0
        for copy in OnboardingCopyCases.copies {
            for state in OnboardingCopyCases.states {
                let screen = copy.screen(state)
                let fullLines = BrandFontsForTests.lineCount(screen.body, bodyFont, width: textWidth)
                let shown = fullLines > 2 ? (screen.fallbackBody ?? screen.body) : screen.body
                let bodyLines = BrandFontsForTests.lineCount(shown, bodyFont, width: textWidth)
                let headlineLines = BrandFontsForTests.lineCount(screen.headline, headlineFont, width: textWidth)
                let depth = fixed
                    + CGFloat(headlineLines) * BrandFontsForTests.lineHeight(headlineFont)
                    + CGFloat(bodyLines) * BrandFontsForTests.lineHeight(bodyFont)
                deepest = max(deepest, depth)
                XCTAssertLessThanOrEqual(depth, layout.thickness, "\(copy.key) \(state): \(Int(depth)) pt")
            }
        }
        print("FIT deepest band state: \(Int(deepest.rounded())) pt of \(Int(layout.thickness))")
    }

    /// 412 pt (`contentWidth` less the `Space.xl` sides) less 5%.
    func testEveryTwoButtonRowFits() {
        let labelFont = BrandFontsForTests.sans(14, .semibold)
        let limit = (layout.contentWidth - 2 * Theme.Space.xl) * 0.95
        for copy in OnboardingCopyCases.copies {
            for state in OnboardingCopyCases.states {
                let buttons = copy.screen(state).row.buttons
                guard buttons.count == 2 else { continue }
                let width = buttons.map { BrandFontsForTests.width($0.title, labelFont) + 2 * (18 + 2) }
                    .reduce(Theme.Space.sm, +)
                XCTAssertLessThanOrEqual(width, limit, "\(state): \(buttons.map(\.title)) is \(Int(width)) pt")
            }
        }
    }
}
