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

/// Objective (mechanical) scoring: keyword rules + WER threshold, with the
/// failure attributed to the stage that caused it. The subjective quality call
/// is Claude Code's, not here.
///
/// The guard verdict is **diagnostic, not a pass/fail criterion**. A guard
/// rejection means the LLM output was discarded and the safe deterministic
/// fallback was used — for a faithfulness case that fallback is the *correct*
/// result and it satisfies the keyword rules, so it must not be marked failed.
/// Conversely, a guard *acceptance* that lets an unfaithful answer through is
/// still caught by `must_not_contain`. So the final output's keyword compliance
/// is the sole mechanical arbiter; `guardVerdict` is surfaced for display only.
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

    public struct StageLatency: Equatable { public let median, p90: Int }
    public struct TargetAggregate: Equatable {
        public let pass, total: Int
        public let latency: [String: StageLatency]  // stage -> latency
    }

    /// Per-target pass rate + latency median/p90 for each stage — the report roll-up.
    public static func aggregate(scores: [RunScore], rows: [ResultRow]) -> [String: TargetAggregate] {
        var passByTarget: [String: (pass: Int, total: Int)] = [:]
        for s in scores {
            var t = passByTarget[s.target] ?? (0, 0)
            t.total += 1; if s.mechanicalPass { t.pass += 1 }
            passByTarget[s.target] = t
        }
        var rowsByTarget: [String: [ResultRow]] = [:]
        for r in rows { rowsByTarget[r.target, default: []].append(r) }

        var out: [String: TargetAggregate] = [:]
        for (target, rs) in rowsByTarget {
            var stageVals: [String: [Int]] = [:]
            for r in rs { for (stage, ms) in r.latencyMs { stageVals[stage, default: []].append(ms) } }
            var latency: [String: StageLatency] = [:]
            for (stage, vals) in stageVals {
                let s = vals.sorted()
                let p90 = s[Swift.min(s.count - 1, Int(0.9 * Double(s.count - 1)))]
                latency[stage] = StageLatency(median: s[s.count / 2], p90: p90)
            }
            let pt = passByTarget[target] ?? (0, 0)
            out[target] = TargetAggregate(pass: pt.pass, total: pt.total, latency: latency)
        }
        return out
    }
}
