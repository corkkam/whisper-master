import EvalScoreKit
import XCTest

@testable import WhisperMaster

/// The public disfluency suite (`eval/text-cleanup/disfluency-cases.jsonl`), and
/// the step that grades it.
///
/// **Why the grading lives here, in Swift.** A case's bar has to be measured from
/// what the model is handed, which is the input after the app's deterministic
/// passes: FillerWordFilter has already taken "um" and "uh" out before any model
/// sees the turn. The first version measured from the raw input, so a turn whose
/// only disfluency was "uh" looked 10% dirty while the model received it clean,
/// and the do-nothing output passed 76 of the 207 cases labelled disfluent.
/// Those passes exist only in Swift, so `make-disfluency-cases.py` extracts input
/// and reference and then runs `testRegenerateTheSuite`, which grades both
/// through `LabDeterministicPipeline`. A Python copy of the filler rules would be
/// a second copy to drift.
final class DisfluencySuiteTests: XCTestCase {
    static let graded = "public-disfluency"
    static let dontDamage = "public-dont-damage"
    /// A case passes within this word error even when it started cleaner, so a
    /// turn the passes already left fluent still fails a model that rewrites it.
    static let floor = 0.10

    struct Grade: Equatable {
        let reference: String
        let category: String
        let limit: Double
        let gap: Double
    }

    /// The reference goes through the same passes, so whatever the app does to
    /// every transcript on its own (digits, a dropped "uh-huh") is in the answer
    /// key too and costs a model nothing. The bar is half the gap the model is
    /// handed, floored; a case the handed text already clears is a don't-damage
    /// case, which only a model that makes things worse can fail.
    static func grade(input: String, reference: String) -> Grade? {
        let handed = LabDeterministicPipeline.run(input)
        let answer = LabDeterministicPipeline.run(reference)
        guard !WER.normalize(handed).isEmpty, !WER.normalize(answer).isEmpty else { return nil }
        let gap = WER.score(reference: answer, hypothesis: handed)
        let limit = (max(floor, gap / 2) * 1000).rounded() / 1000
        // The scorer's own comparison, so the label and the verdict cannot disagree.
        let noOpFails = gap > limit + 1e-9
        return Grade(reference: answer, category: noOpFails ? graded : dontDamage, limit: limit, gap: gap)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - The committed suite

    func testTheRealDisfluencySuiteLoads() throws {
        let loaded = try LabSuiteLoader.load(.disfluency, repoRoot: repoRoot)
        XCTAssertEqual(loaded.cases.count, 250, "the DisfluencySpeech test split, one case per turn")
        XCTAssertTrue(loaded.cases.allSatisfy { $0.target == .light })

        var graded = 0
        for (id, source) in loaded.sources {
            let reference = try XCTUnwrap(source.reference, "\(id) has no reference")
            let limit = try XCTUnwrap(source.maxReferenceWER, "\(id) has no limit, so it can only pass")
            XCTAssertFalse(reference.isEmpty, id)
            XCTAssertGreaterThanOrEqual(limit, Self.floor, id)

            // The do-nothing output is what ships when the model returns nothing
            // or the guard rejects it: the deterministic passes alone.
            let input = try XCTUnwrap(source.inputText, id)
            let noOp = Scorer.score(evalCase: source, row: row(id, LabDeterministicPipeline.run(input)))
            switch source.category {
            case Self.graded:
                graded += 1
                XCTAssertFalse(noOp.mechanicalPass, "\(id): doing nothing passes a case labelled disfluent")
            case Self.dontDamage:
                XCTAssertTrue(noOp.mechanicalPass, "\(id): labelled don't-damage, but doing nothing fails it")
            default:
                XCTFail("\(id): unexpected category \(source.category)")
            }
        }
        // A regeneration that quietly moved every turn to don't-damage would leave
        // a suite that measures nothing while every assertion above held. 62 of the
        // 250 are graded today: most turns' only disfluency is a filler the passes
        // already remove, or a discourse marker the reference keeps.
        XCTAssertGreaterThanOrEqual(graded, 50, "only \(graded) cases are ones a no-op fails")
    }

    /// The grade the file carries is the grade the passes give today. When this
    /// fails after a change to FillerWordFilter or ITN, regenerate the suite.
    func testTheCommittedGradesMatchTheDeterministicPasses() throws {
        let loaded = try LabSuiteLoader.load(.disfluency, repoRoot: repoRoot)
        for (id, source) in loaded.sources {
            let grade = try XCTUnwrap(Self.grade(input: source.inputText ?? "", reference: source.reference ?? ""))
            XCTAssertEqual(source.category, grade.category, "\(id): run make-disfluency-cases.py")
            XCTAssertEqual(source.maxReferenceWER ?? -1, grade.limit, accuracy: 1e-9, "\(id): run make-disfluency-cases.py")
        }
    }

    func testAFillerTheFilterRemovesIsNotADisfluencyToGrade() throws {
        let grade = try XCTUnwrap(Self.grade(
            input: "So, uh, we do have a very low tax rate.",
            reference: "So, we do have a very low tax rate."))
        XCTAssertEqual(grade.gap, 0, accuracy: 1e-9, "FillerWordFilter already took the uh out")
        XCTAssertEqual(grade.category, Self.dontDamage)
        XCTAssertEqual(grade.limit, Self.floor)
    }

    func testARestartIsGradedAtHalfItsGap() throws {
        let grade = try XCTUnwrap(Self.grade(
            input: "Yeah, Steve's mom finally, finally said that, that God will take care of us.",
            reference: "Yeah, Steve's mom finally said that God will take care of us."))
        XCTAssertEqual(grade.category, Self.graded)
        XCTAssertGreaterThan(grade.gap, grade.limit)
        XCTAssertEqual(grade.limit, max(Self.floor, (grade.gap / 2 * 1000).rounded() / 1000), accuracy: 1e-9)
    }

    // MARK: - Regeneration (run by make-disfluency-cases.py)

    /// Reads `WM_DISFLUENCY_RAW` (one `{id, input, reference, note}` per line),
    /// grades every case, and writes the suite to `WM_DISFLUENCY_OUT`. Skipped
    /// unless both are set, so a plain `swift test` never touches the file.
    func testRegenerateTheSuite() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawPath = env["WM_DISFLUENCY_RAW"], let outPath = env["WM_DISFLUENCY_OUT"] else {
            throw XCTSkip("set WM_DISFLUENCY_RAW and WM_DISFLUENCY_OUT, or run make-disfluency-cases.py")
        }
        var lines: [String] = []
        for line in try String(contentsOfFile: rawPath, encoding: .utf8).split(separator: "\n") {
            let raw = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String] ?? [:]
            guard let id = raw["id"], let input = raw["input"], let reference = raw["reference"],
                  let grade = Self.grade(input: input, reference: reference)
            else { continue }
            let note = "\(raw["note"] ?? id), the deterministic passes leave it "
                + "\(Int((grade.gap * 100).rounded()))% from the reference"
            lines.append(try Self.caseLine(id: id, grade: grade, input: input, note: note))
        }
        XCTAssertFalse(lines.isEmpty)
        try (lines.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    /// One case, keys in reading order and numbers in their shortest form, so a
    /// regeneration rewrites the file byte for byte and a diff of it reads.
    static func caseLine(id: String, grade: Grade, input: String, note: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func json(_ string: String) throws -> String {
            String(decoding: try encoder.encode(string), as: UTF8.self)
        }
        var limit = String(format: "%.3f", grade.limit)
        while limit.hasSuffix("0") { limit.removeLast() }
        if limit.hasSuffix(".") { limit.removeLast() }
        return "{\"id\": \(try json(id)), \"category\": \(try json(grade.category)), "
            + "\"input\": {\"text\": \(try json(input))}, \"targets\": [\"light\"], "
            + "\"reference\": \(try json(grade.reference)), \"max_reference_wer\": \(limit), "
            + "\"note\": \(try json(note))}"
    }

    private func row(_ id: String, _ output: String) -> ResultRow {
        ResultRow(id: id, target: "light", inputKind: "text", asrText: nil, asrReference: nil,
                  llmOutput: output, guardVerdict: GuardVerdict(accepted: false),
                  latencyMs: [:], wer: nil)
    }
}
