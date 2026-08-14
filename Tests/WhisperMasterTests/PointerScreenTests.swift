import XCTest

@testable import WhisperMaster

/// Which display the notch sits on is a geometry question, not an NSScreen one —
/// `NSScreen` can't be constructed under `swift test`.
final class PointerScreenTests: XCTestCase {
    /// A 14" laptop on the left, a 27" external on the right, sharing an edge.
    private let sideBySide: [CGRect] = [
        CGRect(x: 0, y: 0, width: 1512, height: 982),
        CGRect(x: 1512, y: 0, width: 1920, height: 1080),
    ]

    /// Laptop below, Studio Display above — a common stacked arrangement.
    private let stacked: [CGRect] = [
        CGRect(x: 0, y: 0, width: 1512, height: 982),
        CGRect(x: 0, y: 982, width: 2560, height: 1440),
    ]

    func testPointerOnTheLeftScreenPicksIt() {
        XCTAssertEqual(PointerScreen.index(containing: CGPoint(x: 100, y: 100), in: sideBySide), 0)
    }

    func testPointerOnTheRightScreenPicksIt() {
        XCTAssertEqual(PointerScreen.index(containing: CGPoint(x: 1600, y: 200), in: sideBySide), 1)
    }

    func testPointerOnTheSharedEdgeBelongsToTheRightScreen() {
        // CGRect.contains is min-inclusive / max-exclusive, so x == 1512 is on
        // the external. The first matching frame would otherwise steal it.
        XCTAssertEqual(PointerScreen.index(containing: CGPoint(x: 1512, y: 100), in: sideBySide), 1)
    }

    func testPointerInAGapReturnsNil() {
        XCTAssertNil(PointerScreen.index(containing: CGPoint(x: -20, y: 100), in: sideBySide))
        XCTAssertNil(PointerScreen.index(containing: CGPoint(x: 4000, y: 100), in: sideBySide))
    }

    func testPointerOnTheDisplayAboveTheLaptopPicksIt() {
        XCTAssertEqual(PointerScreen.index(containing: CGPoint(x: 200, y: 1200), in: stacked), 1)
        XCTAssertEqual(PointerScreen.index(containing: CGPoint(x: 200, y: 100), in: stacked), 0)
    }

    func testEmptyArrangementReturnsNil() {
        XCTAssertNil(PointerScreen.index(containing: CGPoint(x: 10, y: 10), in: []))
    }
}
