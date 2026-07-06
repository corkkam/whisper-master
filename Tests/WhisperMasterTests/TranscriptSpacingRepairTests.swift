import XCTest

@testable import WhisperMaster

final class TranscriptSpacingRepairTests: XCTestCase {
    func testQuestionMarkGluedToNextWord() {
        XCTAssertEqual(TranscriptSpacingRepair.repair("is it working right?The next one"),
                       "is it working right? The next one")
    }

    func testPeriodGluedToNextWord() {
        XCTAssertEqual(TranscriptSpacingRepair.repair("looks good I guess.Yeah it works"),
                       "looks good I guess. Yeah it works")
    }

    func testCommaGluedToCapital() {
        XCTAssertEqual(TranscriptSpacingRepair.repair("Yeah.,But it works"),
                       "Yeah., But it works")
    }

    func testEmailIsNotBroken() {
        XCTAssertEqual(TranscriptSpacingRepair.repair("mail me at john.smith@gmail.com"),
                       "mail me at john.smith@gmail.com")
    }

    func testDecimalAndAbbreviationUntouched() {
        XCTAssertEqual(TranscriptSpacingRepair.repair("it's 3.5 gigs, e.g. the big one"),
                       "it's 3.5 gigs, e.g. the big one")
    }

    func testAlreadySpacedIsUnchanged() {
        let text = "This is fine. Nothing to repair here."
        XCTAssertEqual(TranscriptSpacingRepair.repair(text), text)
    }

    func testEmpty() {
        XCTAssertEqual(TranscriptSpacingRepair.repair(""), "")
    }
}
