import XCTest
@testable import EvalScoreKit

/// These lock the exclusions in `Metrics.novelWords`. The metric is only useful
/// if the transformations the pipeline is *built* to make do not register as
/// inventions — otherwise every number case in the suite reads as a
/// hallucination and the signal is unusable.
final class MetricsTests: XCTestCase {
    private func evalCase(_ id: String = "x", category: String = "numbers",
                          reference: String? = nil) -> EvalCase {
        var obj = #"{"id":"\#(id)","category":"\#(category)","input":{"text":"t"}"#
        if let reference { obj += #","reference":"\#(reference)""# }
        return try! EvalCase.decode(obj + "}")
    }

    private func row(det: String, out: String, llmMs: Int? = nil,
                     accepted: Bool = true) -> ResultRow {
        ResultRow(id: "x", target: "light", inputKind: "text", asrText: nil,
                  asrReference: nil, deterministic: det, llmOutput: out,
                  guardVerdict: .init(accepted: accepted),
                  latencyMs: llmMs.map { ["llm": $0] } ?? [:], wer: nil)
    }

    // MARK: novel words

    func testInverseTextNormalizationIsNotNovel() {
        // "twenty five" -> "$25" is the job, not an invention.
        let n = Metrics.novelWords(input: WER.normalize("it costs twenty five"),
                                  output: WER.normalize("It costs $25."))
        XCTAssertEqual(n, [])
    }

    func testAssembledInitialismIsNotNovel() {
        let n = Metrics.novelWords(input: WER.normalize("our a p i is slow"),
                                  output: WER.normalize("Our API is slow."))
        XCTAssertEqual(n, [])
    }

    func testContractionJoinIsNotNovel() {
        let n = Metrics.novelWords(input: WER.normalize("i do not think so"),
                                  output: WER.normalize("I don't think so."))
        XCTAssertEqual(n, [])
    }

    func testAnsweredQuestionIsNovel() {
        // The failure this metric exists for: the model answered instead of
        // punctuating, so the answer's words are in the output and nowhere else.
        let n = Metrics.novelWords(input: WER.normalize("what is the capital of france"),
                                  output: WER.normalize("The capital of France is Paris."))
        XCTAssertEqual(n, ["paris"])
    }

    func testNovelWordsAreDeduplicated() {
        let n = Metrics.novelWords(input: WER.normalize("hello"),
                                  output: WER.normalize("hello Paris Paris Paris"))
        XCTAssertEqual(n, ["paris"])
    }

    // MARK: retention and edit rate

    func testRetentionCatchesADropThatKeywordsWouldMiss() {
        let det = String(repeating: "word ", count: 100)
        let m = Metrics.measure(evalCase: evalCase(), row: row(det: det, out: String(repeating: "word ", count: 40)))
        XCTAssertEqual(m.retention, 0.40, accuracy: 0.001)
        XCTAssertEqual(m.inputWords, 100)
    }

    func testPunctuationOnlyPassIsFullRetentionAndZeroEdits() {
        let m = Metrics.measure(evalCase: evalCase(),
                                row: row(det: "hello there how are you",
                                         out: "Hello there, how are you?"))
        XCTAssertEqual(m.retention, 1.0)
        // Case and punctuation are stripped by `WER.normalize`, so a pass that
        // only punctuated has an edit rate of zero — which is exactly the reading
        // we want: the *words* were untouched.
        XCTAssertEqual(m.editRate, 0.0)
        XCTAssertEqual(m.novelWordRate, 0.0)
    }

    func testEditRateCountsRewriting() {
        let m = Metrics.measure(evalCase: evalCase(),
                                row: row(det: "one two three four", out: "alpha beta three four"))
        XCTAssertEqual(m.editRate, 0.5, accuracy: 0.001)
    }

    func testEmptyDeterministicDoesNotProduceNaN() {
        let m = Metrics.measure(evalCase: evalCase(), row: row(det: "", out: ""))
        XCTAssertEqual(m.retention, 1.0)
        XCTAssertEqual(m.editRate, 0.0)
        XCTAssertNil(m.msPerWord)
    }

    // MARK: reference WER and ms/word

    func testReferenceWERIsMeasuredOnlyWhenTheCaseCarriesOne() {
        XCTAssertNil(Metrics.measure(evalCase: evalCase(), row: row(det: "a b", out: "a b")).referenceWER)
        let m = Metrics.measure(evalCase: evalCase(reference: "the cat sat"),
                                row: row(det: "the cat sat", out: "The cat stood."))
        XCTAssertEqual(m.referenceWER!, 1.0 / 3.0, accuracy: 0.001)
    }

    func testMsPerWordNormalizesLatencyByLength() {
        let short = Metrics.measure(evalCase: evalCase(), row: row(det: "a b c d e", out: "a b c d e", llmMs: 100))
        let long = Metrics.measure(evalCase: evalCase(),
                                   row: row(det: String(repeating: "w ", count: 500),
                                            out: String(repeating: "w ", count: 500), llmMs: 10_000))
        XCTAssertEqual(short.msPerWord!, 20, accuracy: 0.01)
        XCTAssertEqual(long.msPerWord!, 20, accuracy: 0.01)
    }
}
