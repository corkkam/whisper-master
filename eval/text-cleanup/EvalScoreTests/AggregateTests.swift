import XCTest
@testable import EvalScoreKit

final class AggregateTests: XCTestCase {
    private func evalCase(_ id: String, _ category: String, must: String) -> EvalCase {
        try! EvalCase.decode(
            #"{"id":"\#(id)","category":"\#(category)","input":{"text":"t"},"must_contain":["\#(must)"]}"#)
    }

    private func row(_ id: String, _ out: String, llmMs: Int = 100,
                     accepted: Bool = true, det: String = "hello world") -> ResultRow {
        ResultRow(id: id, target: "light", inputKind: "text", asrText: nil, asrReference: nil,
                  deterministic: det, llmOutput: out, guardVerdict: .init(accepted: accepted),
                  latencyMs: ["llm": llmMs], wer: nil)
    }

    /// A weighted score separates "we missed an acronym" from "we answered the
    /// user's question". Unweighted, both are one failure.
    func testWeightedPassPenalizesFaithfulnessMoreThanNumbers() {
        let cases = [evalCase("n", "numbers", must: "25"), evalCase("f", "faithfulness", must: "verbatim")]
        let rows = [row("n", "nope"), row("f", "verbatim")]
        let scores = zip(cases, rows).map { Scorer.score(evalCase: $0, row: $1) }
        let a = Scorer.aggregate(scores: scores, rows: rows)["light"]!
        XCTAssertEqual(a.pass, 1); XCTAssertEqual(a.total, 2)
        XCTAssertEqual(a.weightedTotal, 4.0)   // 1.0 numbers + 3.0 faithfulness
        XCTAssertEqual(a.weightedPass, 3.0)    // the faithfulness one passed

        // Flip which one fails: the same 1/2 raw, a much worse weighted score.
        let rows2 = [row("n", "25"), row("f", "nope")]
        let scores2 = zip(cases, rows2).map { Scorer.score(evalCase: $0, row: $1) }
        let b = Scorer.aggregate(scores: scores2, rows: rows2)["light"]!
        XCTAssertEqual(b.pass, 1)
        XCTAssertEqual(b.weightedPass, 1.0)
    }

    func testGuardFallbackRateIsReportedAndIsNotAFailure() {
        let cases = [evalCase("a", "numbers", must: "x"), evalCase("b", "numbers", must: "x")]
        let rows = [row("a", "x", accepted: false), row("b", "x", accepted: true)]
        let scores = zip(cases, rows).map { Scorer.score(evalCase: $0, row: $1) }
        let a = Scorer.aggregate(scores: scores, rows: rows)["light"]!
        XCTAssertEqual(a.pass, 2)                     // a rejection is the safe fallback
        XCTAssertEqual(a.guardFallbackRate, 0.5)      // and it is still counted
    }

    func testCategoryRollUpSurfacesAFullyRedCategory() {
        let cases = [evalCase("n1", "numbers", must: "1"), evalCase("n2", "numbers", must: "2"),
                     evalCase("f1", "faithfulness", must: "keep")]
        let rows = [row("n1", "1"), row("n2", "2"), row("f1", "answered")]
        let scores = zip(cases, rows).map { Scorer.score(evalCase: $0, row: $1) }
        let byCat = Scorer.aggregateByCategory(scores: scores)
        XCTAssertEqual(byCat["numbers"]?.pass, 2)
        XCTAssertEqual(byCat["faithfulness"]?.pass, 0)
        XCTAssertEqual(byCat["faithfulness"]?.total, 1)
    }

    /// The old inline index truncated toward the median, so a two-row target's
    /// "p90" latency was its *fastest* row.
    func testPercentileIndexDoesNotCollapseOnSmallSamples() {
        XCTAssertEqual(Scorer.percentileIndex(2, 0.9), 1)
        XCTAssertEqual(Scorer.percentileIndex(1, 0.9), 0)
        XCTAssertEqual(Scorer.percentileIndex(10, 0.9), 8)
        XCTAssertEqual(Scorer.percentileIndex(100, 0.99), 98)
        XCTAssertEqual(Scorer.percentileIndex(0, 0.9), 0)
    }

    func testWorstEndFollowsTheDirectionOfTheDefect() {
        // Retention: low is the defect. Edit rate: high is.
        XCTAssertEqual(Scorer.distribution([0.4, 1.0, 1.1], worst: .low).worst, 0.4)
        XCTAssertEqual(Scorer.distribution([0.0, 0.2, 0.9], worst: .high).worst, 0.9)
        XCTAssertEqual(Scorer.distribution([], worst: .low).count, 0)
    }

    /// Aggregation matches scores to rows by target, not by array position — a
    /// run whose rows come back reordered must produce identical numbers.
    func testAggregateIsOrderIndependent() {
        let cases = [evalCase("a", "numbers", must: "x"), evalCase("b", "numbers", must: "y")]
        let rows = [row("a", "x", llmMs: 50), row("b", "nope", llmMs: 400)]
        let scores = zip(cases, rows).map { Scorer.score(evalCase: $0, row: $1) }
        let forward = Scorer.aggregate(scores: scores, rows: rows)["light"]!
        let reversed = Scorer.aggregate(scores: scores.reversed(), rows: rows.reversed())["light"]!
        XCTAssertEqual(forward, reversed)
    }
}
