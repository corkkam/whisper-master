import XCTest

@testable import WhisperMaster

final class FillerWordFilterTests: XCTestCase {
    func testMidSentenceFiller() {
        XCTAssertEqual(FillerWordFilter.clean("hello um there"), "hello there")
    }

    func testSentenceInitialFillerWithCommaRecapitalizes() {
        XCTAssertEqual(FillerWordFilter.clean("Um, hello there."), "Hello there.")
    }

    func testFillerBetweenCommas() {
        XCTAssertEqual(FillerWordFilter.clean("That was, uh, great."), "That was, great.")
    }

    func testFillerOnlyInputBecomesEmpty() {
        XCTAssertEqual(FillerWordFilter.clean("Hmm."), "")
        XCTAssertEqual(FillerWordFilter.clean("Mm-hmm."), "")
        XCTAssertEqual(FillerWordFilter.clean("uh um hmm"), "")
    }

    func testRealWordsContainingFillerSoundsSurvive() {
        XCTAssertEqual(
            FillerWordFilter.clean("a summer umbrella under the era"),
            "a summer umbrella under the era"
        )
    }

    func testRepeatedAndStretchedFillers() {
        XCTAssertEqual(
            FillerWordFilter.clean("So ummm I was uhh thinking"),
            "So I was thinking"
        )
    }

    func testHyphenatedFillers() {
        XCTAssertEqual(FillerWordFilter.clean("Uh-huh, sounds good."), "Sounds good.")
    }

    func testSentenceFinalPunctuationOnFillerIsKept() {
        XCTAssertEqual(FillerWordFilter.clean("That's all, hmm."), "That's all.")
        XCTAssertEqual(FillerWordFilter.clean("What is that, huh?"), "What is that?")
    }

    func testFillerBetweenSentencesRecapitalizes() {
        XCTAssertEqual(
            FillerWordFilter.clean("It works. um next we ship it."),
            "It works. Next we ship it."
        )
    }

    func testAllCapsAcronymsAreNotFillers() {
        XCTAssertEqual(
            FillerWordFilter.clean("she went to the ER yesterday"),
            "she went to the ER yesterday"
        )
    }

    func testMixedCaseWordIsNeverRecapitalized() {
        XCTAssertEqual(FillerWordFilter.clean("Um, iPhone is here."), "iPhone is here.")
    }

    func testAmbiguousWordsAreLeftAlone() {
        XCTAssertEqual(
            FillerWordFilter.clean("I like it, so well done"),
            "I like it, so well done"
        )
    }

    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(FillerWordFilter.clean(""), "")
        XCTAssertEqual(FillerWordFilter.clean("   "), "")
    }

    func testCleanTextPassesThroughUnchanged() {
        let text = "The quick brown fox jumps over the lazy dog."
        XCTAssertEqual(FillerWordFilter.clean(text), text)
    }
}
