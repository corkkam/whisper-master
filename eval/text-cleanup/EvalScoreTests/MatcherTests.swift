import XCTest
@testable import EvalScoreKit

/// The suite forbids the filler `"um"` in seven cases. Plain `contains` also
/// finds it inside "number", "summary" and "documentation", so those cases were
/// failing on the transcript's vocabulary rather than on a filler. These lock
/// the word-boundary semantics — and the punctuation carve-out that keeps every
/// other assertion in the suite meaning what it says.
final class MatcherTests: XCTestCase {
    func testShortFillerDoesNotMatchInsideALongerWord() {
        XCTAssertFalse(Scorer.matches("um", in: "The number of documents in the summary."))
        XCTAssertTrue(Scorer.matches("um", in: "So um, I think we should ship."))
        XCTAssertFalse(Scorer.matches("uh", in: "Although the throughput held."))
        XCTAssertTrue(Scorer.matches("uh", in: "uh, let me start again"))
    }

    func testMeridiemDoesNotMatchInsideAWord() {
        XCTAssertFalse(Scorer.matches("AM", in: "The same example campaign."))
        XCTAssertTrue(Scorer.matches("AM", in: "Let us meet at 9 AM."))
        XCTAssertFalse(Scorer.matches("PM", in: "A campaign shipped."))
    }

    func testNumberDoesNotMatchInsideALongerNumber() {
        XCTAssertFalse(Scorer.matches("20", in: "It closed in 2025."))
        XCTAssertFalse(Scorer.matches("30", in: "It cost $300."))
        XCTAssertTrue(Scorer.matches("30", in: "About 30 minutes."))
        XCTAssertTrue(Scorer.matches("40", in: "Throughput is up 40%."))
    }

    /// The carve-out. A term with punctuation or whitespace means exactly the
    /// characters it names — a word boundary around it would not be where the
    /// author meant it.
    func testPunctuationTermsStayPlainSubstrings() {
        XCTAssertTrue(Scorer.matches("$25", in: "It is $25."))
        XCTAssertTrue(Scorer.matches("\n- ", in: "items:\n- one\n- two"))
        XCTAssertTrue(Scorer.matches("1.", in: "1. First\n2. Second"))
        XCTAssertTrue(Scorer.matches("Best,", in: "Thanks.\n\nBest,\nSam"))
        XCTAssertTrue(Scorer.matches("github.com/corkkam", in: "See github.com/corkkam/whisper."))
        XCTAssertTrue(Scorer.matches("shobhit@gmail.com", in: "Mail shobhit@gmail.com now."))
        // A punctuation term is still a substring, including inside a word.
        XCTAssertTrue(Scorer.matches("is@", in: "The repo is@github.com/x."))
    }

    func testWordTermMatchesAcrossPunctuationBoundaries() {
        XCTAssertTrue(Scorer.matches("PR", in: "Can you review the PR?"))
        XCTAssertTrue(Scorer.matches("4", in: "The meeting is at 4:00."))
        XCTAssertTrue(Scorer.matches("API", in: "Our API is slow."))
        // Deliberate: an inflection is a different word. A case that wants the
        // looser reading spells the suffix out.
        XCTAssertFalse(Scorer.matches("PR", in: "Both PRs are open."))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(Scorer.matches("thursday", in: "Cut over on Thursday."))
        XCTAssertTrue(Scorer.matches("UM", in: "so um yeah"))
    }

    /// The lint the CLI prints: which assertions the two matchers disagree on,
    /// so an author can see what was load-bearing on the old behaviour.
    func testDisagreementsAreReported() {
        let c = try! EvalCase.decode(
            #"{"id":"real-email","category":"realistic","input":{"text":"t"},"must_not_contain":["um"]}"#)
        let row = ResultRow(id: "real-email", target: "light", inputKind: "text", asrText: nil,
                            asrReference: nil, deterministic: "d",
                            llmOutput: "The number is in the summary.",
                            guardVerdict: .init(accepted: true), latencyMs: [:], wer: nil)
        let d = Scorer.matcherDisagreements(cases: [c], rows: [row])
        XCTAssertEqual(d.count, 1)
        XCTAssertTrue(d[0].contains("substring true, word false"))
        // And the case now passes, where it used to fail on "number".
        XCTAssertTrue(Scorer.score(evalCase: c, row: row).mechanicalPass)
    }
}
