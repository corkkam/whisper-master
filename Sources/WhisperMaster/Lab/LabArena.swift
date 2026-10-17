import Foundation

#if SWIFT_PACKAGE
import EvalScoreKit
#endif

/// An arena ranking over one run: every pair of models meets on every case, and
/// the head-to-head results become one rating per model, on the Elo scale an LLM
/// arena prints.
///
/// **Why a rating when the run already has a pass rate.** A pass rate says how
/// often each model cleared the bar; it cannot say which of two models that both
/// cleared it did better, and with four or more models the table ties a lot. The
/// arena breaks those ties case by case — on reference word error where the case
/// has a reference — and folds the result into a Bradley-Terry fit, so a model
/// that wins narrowly and often ranks above one that wins rarely and big.
///
/// How one case is decided between two models:
/// 1. A pass beats a fail.
/// 2. Both passed or both failed, and the case has a `reference`: the lower word
///    error against it wins, if the gap is at least one word in twenty.
/// 3. Otherwise a tie, which counts as half a win each.
///
/// The ratings are a fit, not a running Elo, so the order the cases ran in does
/// not move them. Every pair also gets one virtual tie, so a model that won
/// every meeting has a finite rating instead of an infinite one.
enum LabArena {
    struct Standing: Equatable, Sendable {
        let modelID: String
        let modelName: String
        /// 1000 is the field's average. 400 points is 10:1 odds per case.
        let rating: Double
        let wins: Int
        let losses: Int
        let ties: Int
    }

    enum Outcome: Equatable { case first, second, tie }

    /// The word error gap below which two outputs count as equally close.
    static let referenceMargin = 0.05

    static func decide(_ a: LabCaseResult, _ b: LabCaseResult, reference: String?) -> Outcome {
        if a.passed != b.passed { return a.passed ? .first : .second }
        guard let reference, !reference.isEmpty else { return .tie }
        let werA = WER.score(reference: reference, hypothesis: a.finalOutput)
        let werB = WER.score(reference: reference, hypothesis: b.finalOutput)
        if abs(werA - werB) < referenceMargin { return .tie }
        return werA < werB ? .first : .second
    }

    /// Ranked best first. Models that failed to run sit out; a case missing from
    /// either side of a pair is skipped for that pair rather than scored.
    static func standings(run: LabRun, references: [String: String] = [:]) -> [Standing] {
        let models = run.models.filter { $0.failure == nil && !$0.cases.isEmpty }
        let n = models.count
        guard n > 0 else { return [] }
        // wins[i][j]: points i took from j, ties as half.
        var points = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        var record = Array(repeating: (wins: 0, losses: 0, ties: 0), count: n)
        let byID = models.map { Dictionary($0.cases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }

        for i in 0 ..< n {
            for j in (i + 1) ..< n {
                for caseA in models[i].cases {
                    guard let caseB = byID[j][caseA.id] else { continue }
                    switch decide(caseA, caseB, reference: references[caseA.id]) {
                    case .first:
                        points[i][j] += 1; record[i].wins += 1; record[j].losses += 1
                    case .second:
                        points[j][i] += 1; record[j].wins += 1; record[i].losses += 1
                    case .tie:
                        points[i][j] += 0.5; points[j][i] += 0.5
                        record[i].ties += 1; record[j].ties += 1
                    }
                }
                points[i][j] += 0.5; points[j][i] += 0.5
            }
        }

        let strength = bradleyTerry(points)
        let logs = strength.map { log10($0) }
        let mean = logs.reduce(0, +) / Double(n)
        return models.indices.map { i in
            Standing(modelID: models[i].modelID, modelName: models[i].modelName,
                     rating: 1000 + 400 * (logs[i] - mean),
                     wins: record[i].wins, losses: record[i].losses, ties: record[i].ties)
        }
        .enumerated()
        .sorted { $0.element.rating != $1.element.rating ? $0.element.rating > $1.element.rating : $0.offset < $1.offset }
        .map(\.element)
    }

    /// Hunter's MM iteration for Bradley-Terry strengths. `points[i][j]` is what i
    /// scored against j. Converges in a few dozen rounds for a handful of models.
    static func bradleyTerry(_ points: [[Double]], rounds: Int = 500) -> [Double] {
        let n = points.count
        var p = Array(repeating: 1.0, count: n)
        for _ in 0 ..< rounds {
            var next = p
            for i in 0 ..< n {
                let won = points[i].reduce(0, +)
                var denominator = 0.0
                for j in 0 ..< n where j != i {
                    let meetings = points[i][j] + points[j][i]
                    if meetings > 0 { denominator += meetings / (p[i] + p[j]) }
                }
                next[i] = denominator > 0 ? won / denominator : p[i]
            }
            let scale = next.reduce(0, +) / Double(n)
            p = next.map { $0 / scale }
        }
        return p
    }
}
