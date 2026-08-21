import XCTest

@testable import WhisperMaster

/// Guards the salvage reconstruction: when the engine's final decode fails, we
/// rebuild from confirmed + volatile. The bug being fixed was salvage returning
/// only the last sliding-window tail; these pin the full-transcript behavior.
final class TranscriptMergerBestEffortTests: XCTestCase {
    func testConfirmedPlusNonOverlappingVolatile() {
        XCTAssertEqual(
            TranscriptMerger.bestEffort(
                confirmed: "the quick brown fox",
                volatile: "jumps over the lazy dog"
            ),
            "the quick brown fox jumps over the lazy dog"
        )
    }

    func testFaithfulJoinMatchesEngineFinish() {
        // Confirmed + volatile are consecutive disjoint segments; the engine's
        // finish() joins them plainly, so salvage must do the same.
        XCTAssertEqual(
            TranscriptMerger.bestEffort(
                confirmed: "i went to the store",
                volatile: "and bought milk"
            ),
            "i went to the store and bought milk"
        )
    }

    func testWhitespaceIsNormalizedAcrossTheSeam() {
        XCTAssertEqual(
            TranscriptMerger.bestEffort(confirmed: "hello  world\n", volatile: "  again"),
            "hello world again"
        )
    }

    func testEmptyConfirmedReturnsVolatile() {
        XCTAssertEqual(
            TranscriptMerger.bestEffort(confirmed: "", volatile: "just the window text"),
            "just the window text"
        )
    }

    func testEmptyVolatileReturnsConfirmed() {
        XCTAssertEqual(
            TranscriptMerger.bestEffort(confirmed: "all confirmed already", volatile: ""),
            "all confirmed already"
        )
    }

    func testLongMultiSentenceIsPreservedNotTruncatedToLastWord() {
        // The regression: a long dictation collapsing to just "word".
        let confirmed = "first sentence here. second sentence follows. third one too"
        let volatile = "and the final word"
        let result = TranscriptMerger.bestEffort(confirmed: confirmed, volatile: volatile)
        XCTAssertEqual(result, "first sentence here. second sentence follows. third one too and the final word")
        XCTAssertTrue(result.contains("first sentence"))
    }

    func testBothEmptyReturnsEmpty() {
        XCTAssertEqual(TranscriptMerger.bestEffort(confirmed: "", volatile: ""), "")
    }
}
