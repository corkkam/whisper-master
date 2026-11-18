import XCTest

@testable import WhisperMaster

/// What the model reads back from a long tool result: ranked rows, a budget, and a
/// stated cut. Pure, so every rule is pinned without a model.
final class ToolResultReducerTests: XCTestCase {
    /// A mail row the way `ToolRouter.read` writes one.
    private func row(_ index: Int, unread: Bool = false, detail: String = "Sam") -> String {
        "Subject number \(index) about the launch plan (\(unread ? "unread · " : "")\(detail)) [Work mail]"
    }

    private func listing(_ rows: [String]) -> String {
        rows.joined(separator: "\n")
    }

    // MARK: - Budget edges

    func testATextAtTheBudgetIsUnchanged() {
        let text = String(repeating: "a", count: 100)
        XCTAssertEqual(ToolResultReducer.reduce(text, budget: 100), text)
    }

    func testOneCharacterOverTheBudgetIsCutAndSaysHowMuch() {
        let text = String(repeating: "a", count: 101)
        let reduced = ToolResultReducer.reduce(text, budget: 100)

        XCTAssertLessThanOrEqual(reduced.count, 100)
        let kept = reduced.prefix { $0 == "a" }.count
        XCTAssertTrue(reduced.hasSuffix("\n[\(101 - kept) more characters not shown]"), reduced)
    }

    /// Only a runaway result is cut: 1,200 words of listing (about 7,000 characters)
    /// reach the model whole.
    func testTheDefaultBudgetIs8000() {
        XCTAssertEqual(ToolResultReducer.budget, 8_000)
        let fits = String(repeating: "word ", count: 1_600)
        XCTAssertEqual(ToolResultReducer.reduce(fits), fits)

        let runaway = String(repeating: "word ", count: 1_601)
        let reduced = ToolResultReducer.reduce(runaway)
        XCTAssertLessThanOrEqual(reduced.count, 8_000)
        XCTAssertTrue(reduced.contains("more characters not shown]"))
    }

    // MARK: - A listing

    func testAListingKeepsWhatFitsAndStatesHowManyRowsWereLeftOut() {
        let rows = (1...40).map { row($0) }
        let reduced = ToolResultReducer.reduce(listing(rows), budget: 800)
        let lines = reduced.components(separatedBy: "\n")

        XCTAssertLessThanOrEqual(reduced.count, 800)
        let kept = lines.dropLast()
        XCTAssertTrue(kept.allSatisfy { rows.contains($0) }, "rows are kept whole")
        XCTAssertEqual(lines.last, "\(40 - kept.count) more not shown.")
        XCTAssertEqual(Array(kept), Array(rows.prefix(kept.count)),
                       "with nothing unread, the first rows in the tool's order are kept")
    }

    /// Unread rows are chosen first, but what the model reads stays in the tool's own
    /// order.
    func testUnreadRowsAreChosenFirstAndShownInTheToolsOrder() {
        let rows = (1...30).map { row($0, unread: $0 > 27) }
        let reduced = ToolResultReducer.reduce(listing(rows), budget: 600)
        let lines = reduced.components(separatedBy: "\n")
        let kept = Array(lines.dropLast())

        for unread in 28...30 {
            XCTAssertTrue(kept.contains(row(unread, unread: true)), "unread row \(unread) is kept")
        }
        XCTAssertEqual(kept.first, row(1), "the read rows that fit come first, as the tool gave them")
        let positions = kept.compactMap { rows.firstIndex(of: $0) }
        XCTAssertEqual(positions, positions.sorted(), "the tool's own order")
        XCTAssertEqual(lines.last, "\(30 - kept.count) more not shown.")
        XCTAssertLessThanOrEqual(reduced.count, 600)
    }

    /// A row too long for the room left is passed over, and a shorter one after it is
    /// still kept.
    func testARowTooLongIsPassedOverForAShorterOne() {
        let long = String(repeating: "Very long preview ", count: 20) + "[Work mail]"
        let rows = [row(1), long, row(2)]
        let budget = row(1).count + 1 + row(2).count + 1 + ToolResultReducer.moreLine(3).count
        let reduced = ToolResultReducer.reduce(listing(rows), budget: budget)

        XCTAssertEqual(reduced, listing([row(1), row(2), ToolResultReducer.moreLine(1)]))
    }

    func testTheHeadingAndAConnectionThatCouldNotBeReadAreKept() {
        let rows = (1...40).map { "9:\($0 < 10 ? "0" : "")\($0) AM — Meeting number \($0) about the roadmap [Work]" }
        let gap = "[Personal] couldn't be read: Sign in again."
        let text = (["Today:"] + rows + [gap]).joined(separator: "\n")
        let reduced = ToolResultReducer.reduce(text, budget: 700)
        let lines = reduced.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "Today:")
        XCTAssertTrue(lines.contains(gap), "a gap is never cut: it is what makes the answer honest")
        XCTAssertTrue(lines.last?.hasSuffix("more not shown.") ?? false)
        XCTAssertLessThanOrEqual(reduced.count, 700)
    }

    /// A row that exactly fills the budget beside the fixed lines is kept; one more
    /// character and it goes.
    func testARowThatExactlyFitsIsKept() {
        let rows = [row(1), row(2), row(3)]
        let moreLine = ToolResultReducer.moreLine(3)
        let twoRows = row(1).count + 1 + row(2).count + 1 + moreLine.count
        let fits = ToolResultReducer.reduce(listing(rows), budget: twoRows)
        XCTAssertEqual(fits, listing([row(1), row(2), ToolResultReducer.moreLine(1)]))

        let short = ToolResultReducer.reduce(listing(rows), budget: twoRows - 1)
        XCTAssertEqual(short, listing([row(1), ToolResultReducer.moreLine(2)]))
    }

    func testOnlyALineEndingInItsConnectionIsARow() {
        XCTAssertTrue(ToolResultReducer.isRow("Launch plan (unread · Sam) [Work mail]"))
        XCTAssertTrue(ToolResultReducer.isRow("Fix [flaky] test [Tracker]"))
        XCTAssertFalse(ToolResultReducer.isRow("[Work mail] couldn't be read: Sign in again."))
        XCTAssertFalse(ToolResultReducer.isRow("Today:"))
        XCTAssertFalse(ToolResultReducer.isRow("A plain sentence."))
    }

    /// A chat or mail preview with line breaks is still one row, so the stated count
    /// is the number of items left out.
    func testARowIsOneLineEvenWhenThePreviewHadLineBreaks() {
        XCTAssertEqual(ToolRouter.oneLine("Ship it\n\nthen tell\r\nthe team"), "Ship it then tell the team")
        XCTAssertTrue(ToolResultReducer.isRow(ToolRouter.oneLine("Ship it\nnow") + " [Work chat]"))
    }

    func testAnUnreadMarkIsReadFromEitherShape() {
        XCTAssertTrue(ToolResultReducer.isUnread("Hi (unread) [Mail]"))
        XCTAssertTrue(ToolResultReducer.isUnread("Hi (unread · Sam) [Mail]"))
        XCTAssertFalse(ToolResultReducer.isUnread("The unread count is high (Sam) [Mail]"))
    }
}
