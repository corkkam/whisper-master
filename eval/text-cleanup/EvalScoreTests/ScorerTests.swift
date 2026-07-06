import XCTest
@testable import EvalScoreKit

final class ScorerTests: XCTestCase {
    private let evalCase = try! EvalCase.decode(
        #"{"id":"x","category":"numbers","input":{"text":"twenty five"},"must_contain":["$25"],"must_not_contain":["25 dollars"]}"#)

    private func row(_ out: String, accepted: Bool = true, wer: Double? = nil) -> ResultRow {
        ResultRow(id: "x", target: "light", inputKind: wer == nil ? "text" : "audio",
                  asrText: nil, asrReference: nil, llmOutput: out,
                  guardVerdict: .init(accepted: accepted), latencyMs: [:], wer: wer)
    }

    func testPassWhenRulesAndGuardOK() {
        XCTAssertTrue(Scorer.score(evalCase: evalCase, row: row("It is $25.")).mechanicalPass)
    }

    func testFailMissingMustContain() {
        let s = Scorer.score(evalCase: evalCase, row: row("It is 25 dollars."))
        XCTAssertFalse(s.mechanicalPass)
        XCTAssertTrue(s.reasons.contains { $0.contains("$25") })
        XCTAssertEqual(s.attribution, "cleanup")
    }

    // A guard rejection is the safe deterministic fallback, not a failure: when
    // the fallback output still satisfies the keyword rules the case passes.
    func testGuardRejectionAloneDoesNotFail() {
        let s = Scorer.score(evalCase: evalCase, row: row("It is $25.", accepted: false))
        XCTAssertTrue(s.mechanicalPass)
        XCTAssertTrue(s.reasons.isEmpty)
    }

    // But an accepted output that violates a keyword rule still fails — the guard
    // verdict never overrides the rules in either direction.
    func testAcceptedButRuleViolatingStillFails() {
        let s = Scorer.score(evalCase: evalCase, row: row("It is 25 dollars.", accepted: true))
        XCTAssertFalse(s.mechanicalPass)
    }

    func testHighWerAttributesToAsr() {
        let s = Scorer.score(evalCase: evalCase, row: row("wrong", wer: 0.5))
        XCTAssertEqual(s.attribution, "asr")
    }

    func testAggregatePassAndLatency() {
        func r(_ out: String, _ llm: Int) -> ResultRow {
            ResultRow(id: "x", target: "light", inputKind: "text", asrText: nil, asrReference: nil,
                      llmOutput: out, guardVerdict: .init(accepted: true),
                      latencyMs: ["llm": llm], wer: nil)
        }
        let rows = [r("It is $25.", 100), r("It is 25 dollars.", 300)]
        let scores = rows.map { Scorer.score(evalCase: evalCase, row: $0) }
        let agg = Scorer.aggregate(scores: scores, rows: rows)
        XCTAssertEqual(agg["light"]?.total, 2)
        XCTAssertEqual(agg["light"]?.pass, 1)                 // one passes, one misses $25
        XCTAssertEqual(agg["light"]?.latency["llm"]?.median, 300)  // sorted [100,300] -> [1]
    }
}
