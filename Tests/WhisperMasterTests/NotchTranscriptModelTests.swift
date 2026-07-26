import XCTest

@testable import WhisperMaster

/// The rolling notch transcript's line breaking and three-line window. Widths are
/// injected, so none of this touches a font.
final class NotchTranscriptModelTests: XCTestCase {

    // MARK: - Tokenizing

    func testTokenizeTagsTheVolatileTail() {
        let words = NotchTranscriptModel.tokenize(confirmed: "locked in", partial: "still moving")
        XCTAssertEqual(words.map(\.text), ["locked", "in", "still", "moving"])
        XCTAssertEqual(words.map(\.isPartial), [false, false, true, true])
    }

    func testTokenizeCollapsesRunsOfWhitespace() {
        let words = NotchTranscriptModel.tokenize(confirmed: "  two   words \n", partial: "")
        XCTAssertEqual(words.map(\.text), ["two", "words"])
    }

    func testTokenizeOfNothingIsEmpty() {
        XCTAssertTrue(NotchTranscriptModel.tokenize(confirmed: "", partial: "   ").isEmpty)
    }

    // MARK: - Line breaking

    func testWrapKeepsWordsOnOneLineWhenTheyFit() {
        // 3 × 10pt words + 2 × 2pt spaces = 34pt, inside a 40pt line.
        let lines = NotchTranscriptModel.wrap(
            widths: [10, 10, 10], spacing: 2, maxWidth: 40)
        XCTAssertEqual(lines, [0..<3])
    }

    func testWrapBreaksWhenTheNextWordWouldOverflow() {
        // The fourth 10pt word would take it to 46pt, past the 40pt line.
        let lines = NotchTranscriptModel.wrap(
            widths: [10, 10, 10, 10], spacing: 2, maxWidth: 40)
        XCTAssertEqual(lines, [0..<3, 3..<4])
    }

    func testWrapCountsTheSpacingBetweenWords() {
        // Without the spacing these four 10pt words would fit a 40pt line exactly.
        let lines = NotchTranscriptModel.wrap(
            widths: [10, 10, 10, 10], spacing: 0, maxWidth: 40)
        XCTAssertEqual(lines, [0..<4])
    }

    func testWordWiderThanTheLineGetsALineToItself() {
        // The oversized word must not loop forever or swallow its neighbours —
        // it takes a line alone and the `Text` truncates it.
        let lines = NotchTranscriptModel.wrap(
            widths: [10, 500, 10], spacing: 2, maxWidth: 40)
        XCTAssertEqual(lines, [0..<1, 1..<2, 2..<3])
    }

    func testWrapOfNoWordsHasNoLines() {
        XCTAssertTrue(NotchTranscriptModel.wrap(widths: [], spacing: 2, maxWidth: 40).isEmpty)
    }

    func testWrapWithNoWidthHasNoLines() {
        // A degenerate band must not produce a line per word forever.
        XCTAssertTrue(NotchTranscriptModel.wrap(widths: [10, 10], spacing: 2, maxWidth: 0).isEmpty)
    }

    func testEveryWordLandsOnExactlyOneLine() {
        let widths = (0..<40).map { CGFloat(6 + $0 % 7) }
        let lines = NotchTranscriptModel.wrap(widths: widths, spacing: 3, maxWidth: 55)
        XCTAssertEqual(lines.flatMap { Array($0) }, Array(0..<40))
    }

    // MARK: - The three-line window

    func testOneLineFillsNothingAndNothingScrolls() {
        let model = NotchTranscriptModel(words: [.init(text: "hi", isPartial: false)], lines: [0..<1])
        XCTAssertEqual(model.visibleLineCount, 1)
        XCTAssertEqual(model.firstVisibleLine, 0)
        XCTAssertFalse(model.hasScrolled)
    }

    func testThreeLinesFillTheWindowWithoutScrolling() {
        let model = NotchTranscriptModel(words: [], lines: [0..<1, 1..<2, 2..<3])
        XCTAssertEqual(model.visibleLineCount, 3)
        XCTAssertEqual(model.firstVisibleLine, 0)
        XCTAssertFalse(model.hasScrolled)
    }

    func testAFourthLineScrollsTheOldestOffTheTop() {
        let model = NotchTranscriptModel(words: [], lines: [0..<1, 1..<2, 2..<3, 3..<4])
        XCTAssertEqual(model.visibleLineCount, 3)
        XCTAssertEqual(model.firstVisibleLine, 1)
        XCTAssertTrue(model.hasScrolled)
    }

    func testAnEmptyModelStillReportsOneLineSoTheBandDoesNotCollapse() {
        XCTAssertEqual(NotchTranscriptModel().visibleLineCount, 1)
        XCTAssertTrue(NotchTranscriptModel().isEmpty)
    }
}
