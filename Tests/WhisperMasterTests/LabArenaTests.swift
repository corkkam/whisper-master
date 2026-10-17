import XCTest

@testable import WhisperMaster

/// The arena's head-to-head rule and the Bradley-Terry fit it feeds.
final class LabArenaTests: XCTestCase {
    func testAPassBeatsAFailWhateverTheWords() {
        let pass = result("a", passed: true, output: "far from the reference")
        let fail = result("a", passed: false, output: "Ship it Monday.")
        XCTAssertEqual(LabArena.decide(pass, fail, reference: "Ship it Monday."), .first)
        XCTAssertEqual(LabArena.decide(fail, pass, reference: "Ship it Monday."), .second)
    }

    // Two passes are told apart by how close each came to the fluent transcript;
    // without a reference they stay a tie, not a coin flip.
    func testReferenceBreaksATieBetweenTwoPasses() {
        let reference = "I don't want this to be a unilateral conversation."
        let clean = result("a", passed: true, output: "I don't want this to be a unilateral conversation.")
        let kept = result("a", passed: true, output: "Well, I don't want to, I don't want this to be a unilateral conversation.")
        XCTAssertEqual(LabArena.decide(clean, kept, reference: reference), .first)
        XCTAssertEqual(LabArena.decide(clean, kept, reference: nil), .tie)
    }

    func testCasingAndPunctuationAloneAreATie() {
        let a = result("a", passed: true, output: "Ship it Monday.")
        let b = result("a", passed: true, output: "ship it monday")
        XCTAssertEqual(LabArena.decide(a, b, reference: "Ship it Monday."), .tie)
    }

    func testStandingsRankTheModelThatWinsMoreMeetings() throws {
        let cases = ["a", "b", "c", "d"]
        let strong = model("strong", cases.map { result($0, passed: true) })
        let middle = model("middle", cases.enumerated().map { result($1, passed: $0 < 2) })
        let weak = model("weak", cases.map { result($0, passed: false) })
        var run = LabRun(id: 1, suite: .disfluency, startedAt: Date(), appVersion: "1", machine: "test")
        run.models = [weak, middle, strong]

        let standings = LabArena.standings(run: run)
        XCTAssertEqual(standings.map(\.modelID), ["strong", "middle", "weak"])
        // Ratings are centred on 1000 and finite even for an unbeaten model.
        let mean = standings.map(\.rating).reduce(0, +) / 3
        XCTAssertEqual(mean, 1000, accuracy: 0.01)
        XCTAssertTrue(standings.allSatisfy { $0.rating.isFinite })
        let top = try XCTUnwrap(standings.first)
        XCTAssertEqual(top.wins, 6)   // 4 over weak, 2 over middle
        XCTAssertEqual(top.losses, 0)
        XCTAssertEqual(top.ties, 2)
    }

    func testAModelThatFailedToRunSitsOut() {
        var broken = model("broken", [])
        broken.failure = "load failed"
        var run = LabRun(id: 1, suite: .cleanup, startedAt: Date(), appVersion: "1", machine: "test")
        run.models = [model("ok", [result("a", passed: true)]), broken]
        XCTAssertEqual(LabArena.standings(run: run).map(\.modelID), ["ok"])
    }

    func testEqualRecordsGetEqualRatings() {
        let strengths = LabArena.bradleyTerry([[0, 3], [3, 0]])
        XCTAssertEqual(strengths[0], strengths[1], accuracy: 1e-9)
    }

    // MARK: - Helpers

    private func result(_ id: String, passed: Bool, output: String = "x") -> LabCaseResult {
        LabCaseResult(
            id: id, category: "test", target: "light", inputKind: "text", prompt: id,
            deterministic: id, modelOutput: output, finalOutput: output,
            guardAccepted: true, passed: passed, latencyMs: 100)
    }

    private func model(_ id: String, _ cases: [LabCaseResult]) -> LabModelResult {
        var result = LabModelResult(modelID: id, modelName: id)
        result.cases = cases
        return result
    }
}

final class LabStopTokensTests: XCTestCase {
    func testOnlyMarkersInTheVocabularyAreUsed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lab-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = #"{"added_tokens":[{"id":1,"content":"<eos>"},{"id":106,"content":"<end_of_turn>"},{"id":2,"content":"<start_of_turn>"}]}"#
        try Data(tokenizer.utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        XCTAssertEqual(LabStopTokens.endOfTurn(in: directory), ["<end_of_turn>"])
    }

    func testAMissingTokenizerAddsNothing() {
        XCTAssertEqual(LabStopTokens.endOfTurn(in: URL(fileURLWithPath: "/nonexistent")), [])
    }
}
