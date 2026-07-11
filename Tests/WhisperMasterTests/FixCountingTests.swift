import XCTest

@testable import WhisperMaster

/// The counting variants the usage dashboard's "fixes" figures are built from.
final class FixCountingTests: XCTestCase {
    // MARK: - FillerWordFilter.cleanCounting

    func testFillerCleanCountingRemovesAndCounts() {
        let (text, removed) = FillerWordFilter.cleanCounting("um hello uh there")
        XCTAssertEqual(removed, 2)
        // Dropping the sentence-opening "um" promotes "hello" to a capital.
        XCTAssertEqual(text, "Hello there")
    }

    func testFillerCleanCountingNoFillers() {
        let (text, removed) = FillerWordFilter.cleanCounting("hello there")
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(text, "hello there")
    }

    func testFillerCleanCountingEmpty() {
        let (text, removed) = FillerWordFilter.cleanCounting("")
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(text, "")
    }

    // MARK: - VocabularyPostProcessor.applyCounting

    func testVocabApplyCountingSubstitutes() {
        let (text, subs) = VocabularyPostProcessor.applyCounting(
            "the laser platform", glossary: ["Lyzr: laser"])
        XCTAssertEqual(subs, 1)
        XCTAssertTrue(text.contains("Lyzr"), "expected canonical term in \"\(text)\"")
        XCTAssertFalse(text.contains("laser"))
    }

    func testVocabApplyCountingNoMatch() {
        let (text, subs) = VocabularyPostProcessor.applyCounting(
            "the platform works", glossary: ["Lyzr: laser"])
        XCTAssertEqual(subs, 0)
        XCTAssertEqual(text, "the platform works")
    }

    func testVocabApplyCountingEmptyGlossary() {
        let (text, subs) = VocabularyPostProcessor.applyCounting("the laser platform", glossary: [])
        XCTAssertEqual(subs, 0)
        XCTAssertEqual(text, "the laser platform")
    }

    // MARK: - SelfCorrectionCollapser.collapseCounting

    func testCollapseCountingSingleCorrection() {
        // "twenty five no forty dollars" (5 tokens) → "forty dollars" (2) → 3 dropped.
        let (text, corrections) = SelfCorrectionCollapser.collapseCounting("twenty five no forty dollars")
        XCTAssertEqual(text, "forty dollars")
        XCTAssertEqual(corrections, 3)
    }

    func testCollapseCountingNoCorrection() {
        let (text, corrections) = SelfCorrectionCollapser.collapseCounting("hello there")
        XCTAssertEqual(text, "hello there")
        XCTAssertEqual(corrections, 0)
    }
}
