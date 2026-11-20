import XCTest

@testable import WhisperMaster

/// When an assistant answer outgrows the one-line band and opens the expanded reply,
/// Copy included.
@MainActor
final class LongAnswerTests: XCTestCase {
    func testTwoHundredTwentyCharactersStillFitTheBand() {
        XCTAssertFalse(AppState.answerIsLong(String(repeating: "a", count: 220)))
        XCTAssertTrue(AppState.answerIsLong(String(repeating: "a", count: 221)))
    }

    func testMoreThanTwoSentencesIsLong() {
        XCTAssertFalse(AppState.answerIsLong("You have two meetings. The first is at ten."))
        XCTAssertTrue(AppState.answerIsLong("Two meetings. First at ten. Then lunch."))
    }

    func testAPointInsideAWordEndsNoSentence() {
        XCTAssertFalse(AppState.answerIsLong("Version 0.6b shipped on the beta at 9.30 today. It works."))
    }

    private func state(answer: String, question: String?) -> AppState {
        let state = AppState()
        state.activeDaySummary = DaySummary(
            headline: answer, detail: "On-device assistant", events: [], gaps: [],
            scopedTo: nil, question: question)
        state.daySummaryAt = Date()
        return state
    }

    func testALongAssistantAnswerOpensTheExpandedBand() {
        let long = "Two meetings. First at ten. Then lunch with the design team."
        XCTAssertTrue(state(answer: long, question: "what's on today").shouldShowExpandedAnswer)
        XCTAssertFalse(state(answer: "Two meetings.", question: "what's on today").shouldShowExpandedAnswer)
    }

    /// The day summary and the media line carry no question and keep their band.
    func testOnlyAnAssistantAnswerOpensIt() {
        let long = "Two meetings. First at ten. Then lunch with the design team."
        XCTAssertFalse(state(answer: long, question: nil).shouldShowExpandedAnswer)
    }

    func testItClosesWithTheAnswerBand() {
        let state = state(answer: "One. Two. Three.", question: "count")
        state.daySummaryAt = Date().addingTimeInterval(-AppState.daySummaryDuration - 1)
        XCTAssertFalse(state.shouldShowExpandedAnswer)
    }
}
