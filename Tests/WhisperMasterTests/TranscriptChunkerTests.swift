import XCTest

@testable import WhisperMaster

final class TranscriptChunkerTests: XCTestCase {

    /// The word budget is not a round number picked by feel — it is the largest
    /// input for which `MlxCleanupService`'s `words * 2 + 32` token budget stays
    /// inside its 512-token generation cap. If either constant moves, this fails
    /// and the pair has to be reconciled on purpose.
    func testTheBudgetIsTheLargestInputThatCannotHitTheGenerationCap() {
        XCTAssertLessThanOrEqual(TranscriptChunker.maxWords * 2 + 32, 512)
        XCTAssertGreaterThan((TranscriptChunker.maxWords + 1) * 2 + 32, 512)
    }

    // MARK: - The short path is untouched

    func testAnOrdinaryDictationIsNotChunkedAtAll() {
        let text = "Ship the report by Thursday. I'll follow up on Friday."
        XCTAssertFalse(TranscriptChunker.needsChunking(text))
        XCTAssertEqual(TranscriptChunker.chunks(text), [text])
    }

    func testEmptyInputYieldsNoChunks() {
        XCTAssertEqual(TranscriptChunker.chunks("   \n  "), [])
    }

    func testExactlyTheBudgetIsStillOnePass() {
        let text = words(TranscriptChunker.maxWords)
        XCTAssertFalse(TranscriptChunker.needsChunking(text))
        XCTAssertEqual(TranscriptChunker.chunks(text).count, 1)
    }

    // MARK: - The invariant: no word is lost or duplicated

    /// The whole point. A chunker that drops a word is a worse bug than the
    /// truncation it exists to prevent, so this is asserted over every shape:
    /// punctuated, unpunctuated, and one enormous sentence.
    func testNoWordIsEverLostOrDuplicated() {
        for text in [longPunctuated(900), words(700), oneLongSentence(600)] {
            let rejoined = TranscriptChunker.chunks(text).joined(separator: " ")
            XCTAssertEqual(
                rejoined.split(separator: " ").map(String.init),
                text.split(separator: " ").map(String.init),
                "chunking must be lossless")
        }
    }

    func testEveryChunkFitsTheBudget() {
        for text in [longPunctuated(900), words(700), oneLongSentence(600)] {
            for chunk in TranscriptChunker.chunks(text) {
                XCTAssertLessThanOrEqual(
                    chunk.split(separator: " ").count, TranscriptChunker.maxWords)
            }
        }
    }

    // MARK: - Where it splits

    /// Sentences are kept whole. Handing the model half a sentence is what makes
    /// a chunked cleanup read worse than an unchunked one.
    func testItSplitsBetweenSentencesRatherThanInsideOne() {
        let sentence = "The quick brown fox jumped over the lazy dog again and again."
        let text = Array(repeating: sentence, count: 60).joined(separator: " ")
        for chunk in TranscriptChunker.chunks(text) {
            XCTAssertTrue(chunk.hasSuffix("."), "a chunk should end where a sentence does")
        }
    }

    /// An unpunctuated ramble is a real ASR output, not a hypothetical — it still
    /// has to be split, just without a boundary to aim at.
    func testAnUnpunctuatedRambleIsStillSplit() {
        let chunks = TranscriptChunker.chunks(oneLongSentence(600))
        XCTAssertGreaterThan(chunks.count, 1)
    }

    /// The terminator rule: a period only ends a sentence when whitespace follows.
    /// Otherwise a spoken email address or a version number becomes a split point
    /// and the model is handed half of it.
    func testADottedTokenIsNotASentenceBoundary() {
        let unit = "Mail support@superwhisper.com about the 0.6b-v3 build please now."
        let text = Array(repeating: unit, count: 60).joined(separator: " ")
        for chunk in TranscriptChunker.chunks(text) {
            XCTAssertFalse(chunk.hasSuffix("support@superwhisper."))
            XCTAssertFalse(chunk.hasSuffix("0."))
        }
    }

    // MARK: - Helpers

    private func words(_ n: Int) -> String {
        (0..<n).map { "word\($0)" }.joined(separator: " ")
    }

    private func oneLongSentence(_ n: Int) -> String {
        words(n)
    }

    private func longPunctuated(_ n: Int) -> String {
        var parts: [String] = []
        var made = 0
        var i = 0
        while made < n {
            let len = min(8, n - made)
            parts.append((0..<len).map { "w\(i + $0)" }.joined(separator: " ") + ".")
            made += len
            i += len
        }
        return parts.joined(separator: " ")
    }
}
