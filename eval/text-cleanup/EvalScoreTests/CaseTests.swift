import XCTest
@testable import EvalScoreKit

final class CaseTests: XCTestCase {
    func testLegacyStringInputWraps() throws {
        let c = try EvalCase.decode(#"{"id":"a","category":"numbers","input":"hello","must_contain":["hello"]}"#)
        XCTAssertEqual(c.inputText, "hello")
        XCTAssertNil(c.inputAudio)
        XCTAssertEqual(c.targets, ["light", "polish"])  // default
        XCTAssertNil(c.reference)
    }

    func testNewSchemaPassthrough() throws {
        let c = try EvalCase.decode(#"{"id":"b","category":"grammar","input":{"text":"x"},"targets":["polish"],"reference":"X."}"#)
        XCTAssertEqual(c.inputText, "x")
        XCTAssertEqual(c.targets, ["polish"])
        XCTAssertEqual(c.reference, "X.")
    }

    func testAudioRequiresAsrReference() {
        XCTAssertThrowsError(try EvalCase.decode(#"{"id":"c","category":"x","input":{"audio":"f.m4a"}}"#))
    }

    func testAudioWithReferenceDecodes() throws {
        let c = try EvalCase.decode(#"{"id":"d","category":"x","input":{"audio":"f.m4a"},"asr_reference":"hello there"}"#)
        XCTAssertEqual(c.inputAudio, "f.m4a")
        XCTAssertEqual(c.asrReference, "hello there")
    }

    func testDestinationTargetsPassthrough() throws {
        let c = try EvalCase.decode(#"{"id":"e","category":"slack","input":{"text":"hey"},"targets":["slack","email","code"]}"#)
        XCTAssertEqual(c.targets, ["slack", "email", "code"])
    }
}
