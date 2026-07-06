import Foundation

/// One row of `results.json` — the runner's per-`case × target` output. Decoded
/// directly from the runner's JSON (see `CodingKeys` for the on-disk names).
public struct GuardVerdict: Decodable {
    public let accepted: Bool
    public init(accepted: Bool) { self.accepted = accepted }
}

public struct ResultRow: Decodable {
    public let id, target, inputKind: String
    public let asrText, asrReference: String?
    public let llmOutput: String
    public let guardVerdict: GuardVerdict
    public let latencyMs: [String: Int]
    public var wer: Double?

    enum CodingKeys: String, CodingKey {
        case id, target, wer
        case inputKind = "input_kind"
        case asrText = "asr_text"
        case asrReference = "asr_reference"
        case llmOutput = "llm_output"
        case guardVerdict = "guard"
        case latencyMs = "latency_ms"
    }

    public init(id: String, target: String, inputKind: String, asrText: String?,
                asrReference: String?, llmOutput: String, guardVerdict: GuardVerdict,
                latencyMs: [String: Int], wer: Double?) {
        self.id = id; self.target = target; self.inputKind = inputKind
        self.asrText = asrText; self.asrReference = asrReference; self.llmOutput = llmOutput
        self.guardVerdict = guardVerdict; self.latencyMs = latencyMs; self.wer = wer
    }
}

public struct RunScore {
    public let id, target: String
    public let mechanicalPass: Bool
    public let reasons: [String]
    /// `"asr"` when a high WER is the likely cause, `"cleanup"` when the text was
    /// heard fine but the cleanup output failed a rule, else `nil` (passed).
    public let attribution: String?
}

/// Objective (mechanical) scoring: keyword rules + guard verdict + WER threshold,
/// with the failure attributed to the stage that caused it. The subjective
/// quality call is Claude Code's, not here.
public enum Scorer {
    public static let werFailThreshold = 0.15

    public static func score(evalCase: EvalCase, row: ResultRow) -> RunScore {
        var reasons: [String] = []
        let low = row.llmOutput.lowercased()
        for term in evalCase.mustContain where !low.contains(term.lowercased()) {
            reasons.append("missing '\(term)'")
        }
        for term in evalCase.mustNotContain where low.contains(term.lowercased()) {
            reasons.append("forbidden '\(term)'")
        }
        if !row.guardVerdict.accepted { reasons.append("guard rejected") }

        var attribution: String?
        if let w = row.wer, w > werFailThreshold {
            attribution = "asr"
            reasons.append("asr wer \(Int(w * 100))%")
        } else if !reasons.isEmpty {
            attribution = "cleanup"
        }

        return RunScore(id: evalCase.id, target: row.target,
                        mechanicalPass: reasons.isEmpty, reasons: reasons,
                        attribution: attribution)
    }
}
