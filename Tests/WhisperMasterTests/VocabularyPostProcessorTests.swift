import XCTest

@testable import WhisperMaster

final class VocabularyPostProcessorTests: XCTestCase {
    func testAliasIsReplacedWithCanonical() {
        XCTAssertEqual(
            VocabularyPostProcessor.apply("the laser agent handles routing", glossary: ["Lyzr: laser, lizer"]),
            "the Lyzr agent handles routing"
        )
    }

    func testCanonicalCasingIsNormalized() {
        XCTAssertEqual(
            VocabularyPostProcessor.apply("it runs on an Nvidia card", glossary: ["NVIDIA"]),
            "it runs on an NVIDIA card"
        )
    }

    func testReplacementIsCaseInsensitive() {
        XCTAssertEqual(
            VocabularyPostProcessor.apply("we love RAG and rag pipelines", glossary: ["RAG: rack"]),
            "we love RAG and RAG pipelines"
        )
    }

    func testWholeWordOnly_DoesNotTouchSubstrings() {
        // "rag" must not corrupt "ragged" or "storage".
        XCTAssertEqual(
            VocabularyPostProcessor.apply("a ragged storage rag", glossary: ["RAG: rag"]),
            "a ragged storage RAG"
        )
    }

    func testPunctuationAroundTermIsPreserved() {
        XCTAssertEqual(
            VocabularyPostProcessor.apply("using laser, then done.", glossary: ["Lyzr: laser"]),
            "using Lyzr, then done."
        )
    }

    func testMultiWordAliasReplacement() {
        XCTAssertEqual(
            VocabularyPostProcessor.apply("the whisper monster app", glossary: ["Whisper Master: whisper monster"]),
            "the Whisper Master app"
        )
    }

    func testEmptyGlossaryAndEmptyTextAreNoOps() {
        XCTAssertEqual(VocabularyPostProcessor.apply("hello world", glossary: []), "hello world")
        XCTAssertEqual(VocabularyPostProcessor.apply("", glossary: ["RAG: rack"]), "")
    }

    func testUnrelatedTextIsUnchanged() {
        let text = "the quick brown fox jumps"
        XCTAssertEqual(VocabularyPostProcessor.apply(text, glossary: ["Lyzr: laser"]), text)
    }

    func testP5RegressionCasing() {
        // The exact vocab-off P5 transcript → all four terms corrected, nothing lost.
        let raw = "We are using Parakeet for transcription and rag pipeline for retrieval. The laser agent handles the routing, and it all runs on the Nvidia card only."
        let out = VocabularyPostProcessor.apply(
            raw, glossary: ["Parakeet", "RAG: rack, rag", "Lyzr: laser, lizer", "NVIDIA"])
        XCTAssertTrue(out.contains("RAG pipeline"), out)
        XCTAssertTrue(out.contains("Lyzr agent"), out)
        XCTAssertTrue(out.contains("NVIDIA card"), out)
        XCTAssertEqual(out.split(whereSeparator: \.isWhitespace).count,
                       raw.split(whereSeparator: \.isWhitespace).count)
    }
}
