import XCTest

@testable import WhisperMaster

final class CorrectionDetectorTests: XCTestCase {
    func testSingleWordReplacementIsDetected() {
        let correction = CorrectionDetector.detectSingleWordReplacement(
            injected: "the laser pipeline is ready",
            current: "the Lyzr pipeline is ready"
        )
        XCTAssertEqual(correction, .init(heard: "laser", typed: "Lyzr"))
    }

    func testReplacementFoundInsideSurroundingText() {
        let correction = CorrectionDetector.detectSingleWordReplacement(
            injected: "ship the rack pipeline today",
            current: "Notes from standup. ship the RAG pipeline today. Next: review."
        )
        XCTAssertEqual(correction, .init(heard: "rack", typed: "RAG"))
    }

    func testUneditedTextReturnsNil() {
        XCTAssertNil(CorrectionDetector.detectSingleWordReplacement(
            injected: "hello there world",
            current: "hello there world"
        ))
    }

    func testStyleEditIsRejectedBySimilarityGate() {
        XCTAssertNil(CorrectionDetector.detectSingleWordReplacement(
            injected: "that was a great demo",
            current: "that was a fantastic demo"
        ))
    }

    func testCaseOnlyChangeIsIgnored() {
        XCTAssertNil(CorrectionDetector.detectSingleWordReplacement(
            injected: "using lyzr for agents",
            current: "using Lyzr for agents"
        ))
    }

    func testTwoChangedWordsReturnsNil() {
        XCTAssertNil(CorrectionDetector.detectSingleWordReplacement(
            injected: "the laser pipeline is ready",
            current: "the Lyzr pipelines is ready"
        ))
    }

    func testTooShortSentenceReturnsNil() {
        XCTAssertNil(CorrectionDetector.detectSingleWordReplacement(
            injected: "laser pipeline",
            current: "Lyzr pipeline"
        ))
    }

    func testDeletedWordsReturnNil() {
        XCTAssertNil(CorrectionDetector.detectSingleWordReplacement(
            injected: "the laser pipeline is ready",
            current: "pipeline is ready"
        ))
    }

    func testPunctuationDoesNotBlockMatching() {
        let correction = CorrectionDetector.detectSingleWordReplacement(
            injected: "Deploy the rack, then verify.",
            current: "Deploy the RAG, then verify."
        )
        XCTAssertEqual(correction, .init(heard: "rack", typed: "RAG"))
    }

    func testGluedPunctuationIsNeverLearned() {
        // Regression: stale field text aligned against a fresh paste taught the
        // glossary "right?The: The" / "guess.Yeah: Yeah", which then rewrote
        // every "the"/"yeah" in every dictation. Must never be learnable.
        XCTAssertNil(CorrectionDetector.detectSingleWordReplacement(
            injected: "this is The test again today",
            current: "this is right?The test again today"
        ))
        XCTAssertNil(CorrectionDetector.detectSingleWordReplacement(
            injected: "I think Yeah we should go",
            current: "I think guess.Yeah we should go"
        ))
    }

    func testContainmentGluingIsNeverLearned() {
        // Regression: "offEverything" ⊇ "Everything" is two glued fragments,
        // not a respelling — learning it poisons every "everything".
        XCTAssertNil(CorrectionDetector.detectSingleWordReplacement(
            injected: "turn Everything off please now",
            current: "turn offEverything off please now"
        ))
    }

    func testRealRespellingStillLearns() {
        // The guards must not break the legitimate case.
        XCTAssertEqual(
            CorrectionDetector.detectSingleWordReplacement(
                injected: "the laser pipeline is ready",
                current: "the Lyzr pipeline is ready"
            ),
            .init(heard: "laser", typed: "Lyzr")
        )
    }

    func testSimilarityMetric() {
        XCTAssertEqual(CorrectionDetector.similarity("rack", "rack"), 1.0)
        XCTAssertGreaterThan(CorrectionDetector.similarity("laser", "lyzr"), 0.3)
        XCTAssertLessThan(CorrectionDetector.similarity("great", "fantastic"), 0.3)
    }
}
