import XCTest

@testable import WhisperMaster

final class DeterministicITNTests: XCTestCase {
    // Regression: a bare "one" was digitized with no context — "one honest
    // footnote" → "1 honest footnote", "one day" → "1 day".
    func testBareOneStaysAWord() {
        XCTAssertEqual(DeterministicITN.normalize("one honest footnote"), "one honest footnote")
        XCTAssertEqual(DeterministicITN.normalize("remind me in one day"), "remind me in one day")
        XCTAssertEqual(DeterministicITN.normalize("one of them is broken"), "one of them is broken")
        XCTAssertEqual(DeterministicITN.normalize("no one showed up"), "no one showed up")
    }

    func testOneWithUnitStillDigitizes() {
        XCTAssertEqual(DeterministicITN.normalize("give me one dollar"), "give me $1")
        XCTAssertEqual(DeterministicITN.normalize("it grew one percent"), "it grew 1%")
    }

    func testMultiWordNumbersStillDigitize() {
        XCTAssertEqual(DeterministicITN.normalize("twenty five people came"), "25 people came")
        XCTAssertEqual(
            DeterministicITN.normalize("send twenty five dollars today"),
            "send $25 today"
        )
    }

    func testTimeStillWorks() {
        XCTAssertEqual(DeterministicITN.normalize("meet at one thirty"), "meet at 1:30")
        XCTAssertEqual(DeterministicITN.normalize("meet at four thirty today"), "meet at 4:30 today")
    }
}
