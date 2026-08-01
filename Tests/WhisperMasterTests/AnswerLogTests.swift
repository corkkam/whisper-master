import XCTest

@testable import WhisperMaster

/// The capped ring behind Today's "Recent answers" card. Pure, so the cap and the
/// ordering are checked here rather than by asking a hundred questions.
final class AnswerLogTests: XCTestCase {

    private func entry(_ answer: String) -> AnsweredQuestion {
        AnsweredQuestion(question: "q", answer: answer)
    }

    func testNewestFirst() {
        var log: [AnsweredQuestion] = []
        log = AnswerLog.appending(entry("first"), to: log)
        log = AnswerLog.appending(entry("second"), to: log)
        XCTAssertEqual(log.map(\.answer), ["second", "first"])
    }

    /// The oldest answers fall off the end — this is a "what did it just tell me" list,
    /// and an unbounded one would grow in `UserDefaults` forever.
    func testTrimsToTheLimitFromTheOldestEnd() {
        var log: [AnsweredQuestion] = []
        for index in 0..<(AnswerLog.limit + 5) {
            log = AnswerLog.appending(entry("answer \(index)"), to: log)
        }
        XCTAssertEqual(log.count, AnswerLog.limit)
        XCTAssertEqual(log.first?.answer, "answer \(AnswerLog.limit + 4)")
        XCTAssertEqual(log.last?.answer, "answer 5")
    }

    /// Survives the `UserDefaults` JSON round trip the store does. The timestamp is
    /// compared with a tolerance because ISO-8601 encodes whole seconds — the same
    /// lossiness the transcript history already has, and irrelevant to a list that
    /// displays a clock time.
    func testRoundTripsThroughCoding() throws {
        let original = AnsweredQuestion(
            question: "what's on my calendar",
            answer: "Three meetings.",
            provenance: "From Work",
            source: .automation)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try XCTUnwrap(
            try decoder.decode([AnsweredQuestion].self, from: encoder.encode([original])).first)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.question, original.question)
        XCTAssertEqual(decoded.answer, original.answer)
        XCTAssertEqual(decoded.provenance, original.provenance)
        XCTAssertEqual(decoded.source, original.source)
        XCTAssertEqual(
            decoded.askedAt.timeIntervalSince1970,
            original.askedAt.timeIntervalSince1970,
            accuracy: 1)
    }
}
