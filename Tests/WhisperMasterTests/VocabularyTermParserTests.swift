import XCTest

@testable import WhisperMaster

final class VocabularyTermParserTests: XCTestCase {
    func testBareTerm() {
        let term = VocabularyTermParser.term(from: "Parakeet")
        XCTAssertEqual(term?.text, "Parakeet")
        XCTAssertNil(term?.aliases)
    }

    func testTermWithAliases() {
        let term = VocabularyTermParser.term(from: "RAG: rag, rack")
        XCTAssertEqual(term?.text, "RAG")
        XCTAssertEqual(term?.aliases, ["rag", "rack"])
    }

    func testWhitespaceIsTrimmedEverywhere() {
        let term = VocabularyTermParser.term(from: "  Lyzr :  liser ,lizer  ")
        XCTAssertEqual(term?.text, "Lyzr")
        XCTAssertEqual(term?.aliases, ["liser", "lizer"])
    }

    func testColonWithNoAliasesFallsBackToBareTerm() {
        let term = VocabularyTermParser.term(from: "macOS:")
        XCTAssertEqual(term?.text, "macOS")
        XCTAssertNil(term?.aliases)
    }

    func testEmptyAndAliasOnlyLinesAreDropped() {
        XCTAssertNil(VocabularyTermParser.term(from: "   "))
        XCTAssertNil(VocabularyTermParser.term(from: ": rack, wrack"))
    }

    func testMultiWordPhrasesSurvive() {
        let term = VocabularyTermParser.term(from: "Whisper Master: whisper monster")
        XCTAssertEqual(term?.text, "Whisper Master")
        XCTAssertEqual(term?.aliases, ["whisper monster"])
    }

    func testTermsFromLines() {
        let terms = VocabularyTermParser.terms(from: ["Parakeet", "", "RAG: rack"])
        XCTAssertEqual(terms.map(\.text), ["Parakeet", "RAG"])
    }
}
