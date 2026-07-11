import XCTest

@testable import WhisperMaster

final class WordCountTests: XCTestCase {
    func testEmptyStringIsZero() {
        XCTAssertEqual(WordCount.count(""), 0)
    }

    func testWhitespaceOnlyIsZero() {
        XCTAssertEqual(WordCount.count("   "), 0)
        XCTAssertEqual(WordCount.count("\n\t  \t\n"), 0)
    }

    func testSingleWord() {
        XCTAssertEqual(WordCount.count("hello"), 1)
        XCTAssertEqual(WordCount.count("  hello  "), 1)
    }

    func testMultipleWords() {
        XCTAssertEqual(WordCount.count("hello there world"), 3)
    }

    func testCollapsesRunsOfWhitespace() {
        // Multiple spaces, tabs, and newlines must not produce empty tokens.
        XCTAssertEqual(WordCount.count("hello    there"), 2)
        XCTAssertEqual(WordCount.count("hello\tthere\nworld"), 3)
        XCTAssertEqual(WordCount.count("  a   b \n\t c  "), 3)
    }
}
