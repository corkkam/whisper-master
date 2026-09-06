import Foundation

/// GPU and process memory at one instant during a run. Sampled on a timer so the
/// page can draw memory *over* a run rather than a single peak figure: a model
/// that sits at 400 MB and spikes to 2 GB on one long case is a different
/// proposition from one that holds 1.2 GB throughout, and one number cannot tell
/// those apart.
struct LabMemorySample: Codable, Sendable, Equatable {
    /// Milliseconds since the model's own run started.
    let atMs: Int
    let activeBytes: Int64
    let cacheBytes: Int64
    let peakBytes: Int64
    let footprintBytes: Int64
}

/// What one model did with one case.
struct LabCaseResult: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let category: String
    let target: String
    let inputKind: String
    /// The words that went in: the case text, the recording's filename, or the
    /// spoken command.
    let prompt: String
    /// After the deterministic passes, before the model. Empty for tool cases.
    let deterministic: String
    /// Exactly what the model returned, guard or no guard.
    let modelOutput: String
    /// What the app would actually have used: the model's output when the guard
    /// accepted it, the deterministic text when it did not.
    let finalOutput: String
    let guardAccepted: Bool
    let passed: Bool
    let reasons: [String]
    /// `"asr"` when a high word error rate explains the failure, `"cleanup"` when
    /// the words were heard right and the pass broke them, else nil.
    let attribution: String?
    let latencyMs: Int
    let asrMs: Int?
    let wer: Double?
    let promptTokens: Int
    let generatedTokens: Int
    let tokensPerSecond: Double
    let expectedTool: String?
    let calledTool: String?
    /// Audio cases only: what the ASR heard, and the words that were read into
    /// the recording. Kept apart from `prompt` (the filename) so the export can
    /// hand the offline scorer the same two strings `EvalRunner` does.
    let asrText: String?
    let asrReference: String?

    init(
        id: String, category: String, target: String, inputKind: String, prompt: String,
        deterministic: String, modelOutput: String, finalOutput: String,
        guardAccepted: Bool, passed: Bool, reasons: [String] = [], attribution: String? = nil,
        latencyMs: Int, asrMs: Int? = nil, wer: Double? = nil,
        promptTokens: Int = 0, generatedTokens: Int = 0, tokensPerSecond: Double = 0,
        expectedTool: String? = nil, calledTool: String? = nil,
        asrText: String? = nil, asrReference: String? = nil
    ) {
        self.id = id; self.category = category; self.target = target
        self.inputKind = inputKind; self.prompt = prompt
        self.deterministic = deterministic; self.modelOutput = modelOutput
        self.finalOutput = finalOutput; self.guardAccepted = guardAccepted
        self.passed = passed; self.reasons = reasons; self.attribution = attribution
        self.latencyMs = latencyMs; self.asrMs = asrMs; self.wer = wer
        self.promptTokens = promptTokens; self.generatedTokens = generatedTokens
        self.tokensPerSecond = tokensPerSecond
        self.expectedTool = expectedTool; self.calledTool = calledTool
        self.asrText = asrText; self.asrReference = asrReference
    }
}

/// One model's whole pass over one suite.
struct LabModelResult: Codable, Identifiable, Sendable, Equatable {
    let modelID: String
    let modelName: String
    /// How long the weights took to load and warm, which is not part of any
    /// case's latency but is very much part of using the model.
    var loadMs: Int = 0
    var diskBytes: Int64 = 0
    /// GPU memory MLX held after the load settled, over what it held before.
    var loadGPUBytes: Int64 = 0
    /// The highest GPU figure seen at any point in this model's run.
    var peakGPUBytes: Int64 = 0
    /// The highest process footprint seen. Includes everything else the app is
    /// doing, so it is the honest "what this costs the machine" number and the
    /// GPU figures are the honest "what the model costs" ones.
    var peakFootprintBytes: Int64 = 0
    var memory: [LabMemorySample] = []
    var cases: [LabCaseResult] = []
    /// Set when the model never got as far as producing results.
    var failure: String?

    var id: String { modelID }

    init(modelID: String, modelName: String) {
        self.modelID = modelID
        self.modelName = modelName
    }

    // MARK: Derived

    var total: Int { cases.count }
    var passed: Int { cases.filter(\.passed).count }
    /// 0 when nothing ran, so an empty result sorts last rather than perfect.
    var scoreFraction: Double { total == 0 ? 0 : Double(passed) / Double(total) }
    var guardRejects: Int { cases.filter { !$0.guardAccepted }.count }

    var p50LatencyMs: Int { LabStats.percentile(cases.map(\.latencyMs), 0.5) }
    var p95LatencyMs: Int { LabStats.percentile(cases.map(\.latencyMs), 0.95) }

    var medianTokensPerSecond: Double {
        let values = cases.map(\.tokensPerSecond).filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return 0 }
        return values[values.count / 2]
    }

    /// Mean word error rate over the cases that have one.
    var meanWER: Double? {
        let values = cases.compactMap(\.wer)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

/// A whole bench run: one suite, several models, kept on disk.
struct LabRun: Codable, Identifiable, Sendable, Equatable {
    /// Monotonic per-Mac sequence number, so the history rail reads "Run 47"
    /// rather than a UUID.
    let id: Int
    let suite: LabSuite
    let startedAt: Date
    var finishedAt: Date?
    let appVersion: String
    /// Which Mac produced this, since a run is only comparable to another run on
    /// the same silicon.
    let machine: String
    var models: [LabModelResult] = []
    /// Set when the run was stopped before it finished.
    var stopped: Bool = false

    var caseCount: Int { models.first?.total ?? 0 }

    func result(modelID: String) -> LabModelResult? { models.first { $0.modelID == modelID } }

    /// Best score first, then fastest. Ties on both keep catalogue order, so the
    /// table does not reshuffle between two identical runs.
    var ranked: [LabModelResult] {
        models.enumerated().sorted { lhs, rhs in
            if lhs.element.scoreFraction != rhs.element.scoreFraction {
                return lhs.element.scoreFraction > rhs.element.scoreFraction
            }
            if lhs.element.p50LatencyMs != rhs.element.p50LatencyMs {
                return lhs.element.p50LatencyMs < rhs.element.p50LatencyMs
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

enum LabStats {
    /// Nearest-rank percentile. Small samples are the normal case here (16 cases
    /// in the tool suite), and interpolation on 16 points invents precision.
    static func percentile(_ values: [Int], _ fraction: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

// MARK: - Comparison

/// How a candidate did against the baseline on one case.
enum LabVerdict: String, Sendable {
    /// Both passed, or both failed. Nothing to look at.
    case agree
    /// The candidate passed where the baseline did not.
    case improvement
    /// The baseline passed and the candidate broke it. The only kind that blocks
    /// a swap.
    case regression
    /// One side has no result for this case at all.
    case missing
}

struct LabComparisonRow: Identifiable, Sendable {
    let id: String
    let category: String
    let target: String
    let prompt: String
    let baseline: LabCaseResult?
    let candidate: LabCaseResult?
    let verdict: LabVerdict

    /// Both sides passed or both failed identically. The filter default hides
    /// these, because 80 rows of "same" is where the 11 interesting ones hide.
    var isAgreement: Bool { verdict == .agree }
}

/// Baseline against candidate, case by case. Pure: it takes two stored results
/// and returns rows, so the whole comparison is tested without a model.
enum LabComparison {
    static func rows(baseline: LabModelResult?, candidate: LabModelResult?) -> [LabComparisonRow] {
        let baselineByID = Dictionary(uniqueKeysWithValues: (baseline?.cases ?? []).map { ($0.id, $0) })
        let candidateByID = Dictionary(uniqueKeysWithValues: (candidate?.cases ?? []).map { ($0.id, $0) })

        // Baseline order first (it is the suite's order), then anything only the
        // candidate ran, so nothing is silently dropped from the comparison.
        var ids = (baseline?.cases ?? []).map(\.id)
        ids += (candidate?.cases ?? []).map(\.id).filter { baselineByID[$0] == nil }

        return ids.map { id in
            let left = baselineByID[id]
            let right = candidateByID[id]
            let sample = left ?? right
            return LabComparisonRow(
                id: id,
                category: sample?.category ?? "",
                target: sample?.target ?? "",
                prompt: sample?.prompt ?? "",
                baseline: left, candidate: right,
                verdict: verdict(baseline: left, candidate: right))
        }
    }

    static func verdict(baseline: LabCaseResult?, candidate: LabCaseResult?) -> LabVerdict {
        guard let baseline, let candidate else { return .missing }
        if baseline.passed == candidate.passed { return .agree }
        return candidate.passed ? .improvement : .regression
    }

    /// The four figures at the top of the compare view. Deltas are candidate
    /// minus baseline, so a positive score delta and a negative latency delta are
    /// both good — the view labels which way is which rather than making the sign
    /// carry it.
    struct Summary: Sendable, Equatable {
        var baselineScore = 0, candidateScore = 0, total = 0
        var baselineP50 = 0, candidateP50 = 0
        var baselinePeakGPU: Int64 = 0, candidatePeakGPU: Int64 = 0
        var baselineGuardRejects = 0, candidateGuardRejects = 0
        var regressions = 0, improvements = 0
    }

    static func summary(baseline: LabModelResult?, candidate: LabModelResult?) -> Summary {
        var summary = Summary()
        summary.baselineScore = baseline?.passed ?? 0
        summary.candidateScore = candidate?.passed ?? 0
        summary.total = max(baseline?.total ?? 0, candidate?.total ?? 0)
        summary.baselineP50 = baseline?.p50LatencyMs ?? 0
        summary.candidateP50 = candidate?.p50LatencyMs ?? 0
        summary.baselinePeakGPU = baseline?.peakGPUBytes ?? 0
        summary.candidatePeakGPU = candidate?.peakGPUBytes ?? 0
        summary.baselineGuardRejects = baseline?.guardRejects ?? 0
        summary.candidateGuardRejects = candidate?.guardRejects ?? 0
        let rows = rows(baseline: baseline, candidate: candidate)
        summary.regressions = rows.filter { $0.verdict == .regression }.count
        summary.improvements = rows.filter { $0.verdict == .improvement }.count
        return summary
    }
}
