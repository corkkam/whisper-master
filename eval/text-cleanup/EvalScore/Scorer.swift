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
    /// The deterministic-pass text — i.e. the LLM's *input*. Every ratio in
    /// `RowMetrics` is measured against this rather than the raw case text, so
    /// the deterministic passes' own edits are not attributed to the model.
    public let deterministic: String?
    public let llmOutput: String
    public let guardVerdict: GuardVerdict
    public let latencyMs: [String: Int]
    public var wer: Double?

    enum CodingKeys: String, CodingKey {
        case id, target, wer, deterministic
        case inputKind = "input_kind"
        case asrText = "asr_text"
        case asrReference = "asr_reference"
        case llmOutput = "llm_output"
        case guardVerdict = "guard"
        case latencyMs = "latency_ms"
    }

    public init(id: String, target: String, inputKind: String, asrText: String?,
                asrReference: String?, deterministic: String? = nil, llmOutput: String,
                guardVerdict: GuardVerdict, latencyMs: [String: Int], wer: Double?) {
        self.id = id; self.target = target; self.inputKind = inputKind
        self.asrText = asrText; self.asrReference = asrReference
        self.deterministic = deterministic; self.llmOutput = llmOutput
        self.guardVerdict = guardVerdict; self.latencyMs = latencyMs; self.wer = wer
    }
}

public struct RunScore {
    public let id, target, category: String
    public let mechanicalPass: Bool
    public let reasons: [String]
    /// `"asr"` when a high WER is the likely cause, `"cleanup"` when the text was
    /// heard fine but the cleanup output failed a rule, else `nil` (passed).
    public let attribution: String?
    /// Continuous measurements beside the verdict — see `RowMetrics`.
    public let metrics: RowMetrics
    /// Diagnostic: true when the guard discarded the LLM output and the safe
    /// deterministic text shipped. Never a failure; aggregated as a *rate*,
    /// because that rate is how often a user gets no benefit from the model.
    public let guardFellBack: Bool
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

        return RunScore(id: evalCase.id, target: row.target, category: evalCase.category,
                        mechanicalPass: reasons.isEmpty, reasons: reasons,
                        attribution: attribution,
                        metrics: Metrics.measure(evalCase: evalCase, row: row),
                        guardFellBack: !row.guardVerdict.accepted)
    }

    /// Severity weight for a failing category. A normalizer that answers a
    /// dictated question or leaks a spoken password has broken the promise the
    /// product is sold on; one that misses an acronym has been mildly annoying.
    /// An unweighted pass count treats those as one failure each, which is why
    /// the weighted score is reported beside it rather than instead of it —
    /// neither number alone tells you whether a run is shippable.
    public static let categoryWeight: [String: Double] = [
        "faithfulness": 3.0,   // invented / answered / rewrote — the trust failure
        "sensitive": 3.0,      // a spoken secret must survive untouched
        "long-form": 2.0,      // a drop here loses text the user cannot recover
        "realistic": 2.0,      // the shapes people actually dictate
        "multilingual": 2.0,   // translating what was said is the faithfulness break
        "idempotency": 2.0,    // a model that cannot leave clean text alone damages every good dictation
        "uri": 1.5,            // a wrong URL or path is wrong silently
        "disfluency": 1.5,
        "numbers": 1.0, "grammar": 1.0, "punctuation": 1.0, "fillers": 1.0,
        "vocabulary": 1.0, "edge": 1.0,
        "slack": 1.0, "email": 1.0, "code": 1.0, "destination": 1.0,
    ]

    public static func weight(for category: String) -> Double {
        categoryWeight[category] ?? 1.0
    }

    public struct StageLatency: Equatable { public let median, p90, p99: Int }
    /// A metric's distribution across the rows it was measured on. `worst` is the
    /// end of the range that indicates a defect — the *minimum* retention (a
    /// drop) but the *maximum* edit rate — so a single column reads the same way
    /// down the whole table.
    public struct Distribution: Equatable {
        public let median, p90, worst, mean: Double
        public let count: Int
    }
    public struct TargetAggregate: Equatable {
        public let pass, total: Int
        public let latency: [String: StageLatency]  // stage -> latency
        /// Weighted pass rate: each row counts `weight(for: category)`.
        public let weightedPass, weightedTotal: Double
        /// Share of rows where the guard discarded the LLM output.
        public let guardFallbackRate: Double
        public let retention, editRate, novelWordRate, msPerWord: Distribution
        /// Only over rows whose case carries a `reference`.
        public let referenceWER: Distribution
        /// Rows the LLM left byte-identical after normalization — the cases that
        /// do not exercise the model at all, and so cannot be evidence for it.
        public let noOpRows: Int
    }
    public struct CategoryAggregate: Equatable {
        public let pass, total: Int
        public let weightedPass, weightedTotal: Double
    }

    /// Per-target roll-up: pass rate, weighted pass rate, stage latency, guard
    /// fallback rate, and the distribution of each continuous metric.
    ///
    /// Scores are matched to rows by `(id, target)` rather than by position, so a
    /// run whose rows are reordered — or one where a case failed to produce a row
    /// for one of its targets — aggregates the same numbers.
    public static func aggregate(scores: [RunScore], rows: [ResultRow]) -> [String: TargetAggregate] {
        var byTarget: [String: [RunScore]] = [:]
        for s in scores { byTarget[s.target, default: []].append(s) }
        var rowsByTarget: [String: [ResultRow]] = [:]
        for r in rows { rowsByTarget[r.target, default: []].append(r) }

        var out: [String: TargetAggregate] = [:]
        for (target, ss) in byTarget {
            let rs = rowsByTarget[target] ?? []
            var stageVals: [String: [Int]] = [:]
            for r in rs { for (stage, ms) in r.latencyMs { stageVals[stage, default: []].append(ms) } }
            var latency: [String: StageLatency] = [:]
            for (stage, vals) in stageVals where !vals.isEmpty {
                let v = vals.sorted()
                latency[stage] = StageLatency(median: v[v.count / 2],
                                              p90: v[percentileIndex(v.count, 0.9)],
                                              p99: v[percentileIndex(v.count, 0.99)])
            }

            let pass = ss.filter(\.mechanicalPass).count
            let wTotal = ss.reduce(0.0) { $0 + weight(for: $1.category) }
            let wPass = ss.filter(\.mechanicalPass).reduce(0.0) { $0 + weight(for: $1.category) }
            let fallbacks = ss.filter(\.guardFellBack).count

            out[target] = TargetAggregate(
                pass: pass, total: ss.count, latency: latency,
                weightedPass: wPass, weightedTotal: wTotal,
                guardFallbackRate: ss.isEmpty ? 0 : Double(fallbacks) / Double(ss.count),
                retention: distribution(ss.map(\.metrics.retention), worst: .low),
                editRate: distribution(ss.map(\.metrics.editRate), worst: .high),
                novelWordRate: distribution(ss.map(\.metrics.novelWordRate), worst: .high),
                msPerWord: distribution(ss.compactMap(\.metrics.msPerWord), worst: .high),
                referenceWER: distribution(ss.compactMap(\.metrics.referenceWER), worst: .high),
                noOpRows: ss.filter { $0.metrics.editRate == 0 }.count)
        }
        return out
    }

    /// Per-category roll-up. `category` is on every case and was never rolled up,
    /// so a suite-wide "174/178" could hide a whole category going red while the
    /// numbers category carried the total. This is the cheapest real signal in
    /// the scorer.
    public static func aggregateByCategory(scores: [RunScore]) -> [String: CategoryAggregate] {
        var byCat: [String: [RunScore]] = [:]
        for s in scores { byCat[s.category, default: []].append(s) }
        return byCat.mapValues { ss in
            CategoryAggregate(
                pass: ss.filter(\.mechanicalPass).count, total: ss.count,
                weightedPass: ss.filter(\.mechanicalPass).reduce(0.0) { $0 + weight(for: $1.category) },
                weightedTotal: ss.reduce(0.0) { $0 + weight(for: $1.category) })
        }
    }

    enum WorstEnd { case low, high }

    static func distribution(_ values: [Double], worst end: WorstEnd) -> Distribution {
        let v = values.filter(\.isFinite).sorted()
        guard !v.isEmpty else { return Distribution(median: 0, p90: 0, worst: 0, mean: 0, count: 0) }
        return Distribution(
            median: v[v.count / 2],
            p90: v[percentileIndex(v.count, 0.9)],
            worst: end == .low ? v[0] : v[v.count - 1],
            mean: v.reduce(0, +) / Double(v.count),
            count: v.count)
    }

    /// Nearest-rank percentile, clamped. Written once because the old inline
    /// `Int(0.9 * Double(n - 1))` truncates toward the median on small samples:
    /// for n = 2 it returns index 0, so the "p90" latency of a two-row target was
    /// its *fastest* row.
    static func percentileIndex(_ count: Int, _ q: Double) -> Int {
        guard count > 0 else { return 0 }
        return Swift.min(count - 1, Swift.max(0, Int((q * Double(count)).rounded(.up)) - 1))
    }
}
