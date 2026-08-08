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
            provenance: "From Work")
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

    /// **The retired `automation` source must not cost the user their log.**
    /// `AnswerLog.load` decodes the whole array under one `try?`, so a strict decode
    /// of a raw value that no longer exists wouldn't drop the one stale row — it
    /// would return `nil` for the array and silently empty the entire answer log.
    func testARowWrittenBeforeAutomationsWereRemovedStillDecodes() throws {
        let legacy = Data(#"""
        [{"id":"6E1A9C4E-2F3B-4A5D-8C7E-1B2A3C4D5E6F","question":"Morning briefing",
          "answer":"Two things need you today.","provenance":"",
          "askedAt":"2026-08-01T09:00:00Z","source":"automation"}]
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([AnsweredQuestion].self, from: legacy)

        XCTAssertEqual(decoded.count, 1, "the row survives rather than taking the log with it")
        XCTAssertEqual(decoded.first?.source, .spoken, "an unknown origin reads as spoken")
        XCTAssertEqual(decoded.first?.answer, "Two things need you today.")
    }
}
