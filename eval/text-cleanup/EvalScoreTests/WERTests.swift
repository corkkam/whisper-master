import XCTest
@testable import EvalScoreKit

final class WERTests: XCTestCase {
    func testIdenticalIsZero() {
        XCTAssertEqual(WER.score(reference: "hello world", hypothesis: "Hello, world!"), 0.0)
    }
    func testOneSubstitution() {
        XCTAssertEqual(WER.score(reference: "the cat sat", hypothesis: "the dog sat"), 1.0 / 3.0, accuracy: 1e-9)
    }
    func testDeletion() {
        XCTAssertEqual(WER.score(reference: "a b c d", hypothesis: "a b d"), 1.0 / 4.0, accuracy: 1e-9)
    }
    func testEmptyReferenceEmptyHypothesis() {
        XCTAssertEqual(WER.score(reference: "", hypothesis: ""), 0.0)
    }
}
