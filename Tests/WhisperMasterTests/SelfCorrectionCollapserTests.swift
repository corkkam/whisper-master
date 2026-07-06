import XCTest

@testable import WhisperMaster

final class SelfCorrectionCollapserTests: XCTestCase {
    // Single correction between two number values — keep the later value.
    func testSingleNumericCorrection() {
        XCTAssertEqual(SelfCorrectionCollapser.collapse("the plan is twenty five no forty dollars a month"),
                       "the plan is forty dollars a month")
        XCTAssertEqual(SelfCorrectionCollapser.collapse("the total comes to fifty no wait sixty dollars"),
                       "the total comes to sixty dollars")
        XCTAssertEqual(SelfCorrectionCollapser.collapse("let's meet at three no four thirty"),
                       "let's meet at four thirty")
    }

    // Chains — "twenty no thirty no forty" collapses to just "forty".
    func testNumericChainKeepsLast() {
        XCTAssertEqual(SelfCorrectionCollapser.collapse("we need twenty no thirty no forty units"),
                       "we need forty units")
        XCTAssertEqual(SelfCorrectionCollapser.collapse("give me five no six no seven"),
                       "give me seven")
    }

    // Other correction markers.
    func testMarkerVariants() {
        XCTAssertEqual(SelfCorrectionCollapser.collapse("we need twenty actually thirty units"),
                       "we need thirty units")
        XCTAssertEqual(SelfCorrectionCollapser.collapse("room ten scratch that twelve"),
                       "room twelve")
    }

    // Must NOT collapse when the marker isn't flanked by two number runs — the
    // gate that prevents false positives on ordinary speech.
    func testDoesNotCollapseOrdinarySpeech() {
        XCTAssertEqual(SelfCorrectionCollapser.collapse("there were no results today"),
                       "there were no results today")
        XCTAssertEqual(SelfCorrectionCollapser.collapse("twenty five people came no problem"),
                       "twenty five people came no problem")
        XCTAssertEqual(SelfCorrectionCollapser.collapse("i actually think we should ship"),
                       "i actually think we should ship")
        // "no wait" not followed by a number is left alone.
        XCTAssertEqual(SelfCorrectionCollapser.collapse("give me twenty no wait let me check"),
                       "give me twenty no wait let me check")
    }

    // A plain number with no correction marker is untouched.
    func testPlainNumbersUntouched() {
        XCTAssertEqual(SelfCorrectionCollapser.collapse("twenty five people came"), "twenty five people came")
        XCTAssertEqual(SelfCorrectionCollapser.collapse("one hundred twenty three"), "one hundred twenty three")
        XCTAssertEqual(SelfCorrectionCollapser.collapse("nothing to change here"), "nothing to change here")
    }
}
