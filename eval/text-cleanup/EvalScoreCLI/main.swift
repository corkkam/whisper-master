import Foundation
import EvalScoreKit

// Usage: eval-score <results.json> <cases.jsonl>
// Reads the runner's results + the cases, computes WER for audio rows, scores
// each row, and prints a pass/fail summary. Cheap and re-runnable — tweak rules
// and re-run without touching the (expensive) model runner.
let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: eval-score <results.json> <cases.jsonl>\n".utf8))
    exit(2)
}

do {
    let rowsData = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    var rows = try JSONDecoder().decode([ResultRow].self, from: rowsData)
    for i in rows.indices where rows[i].inputKind == "audio" {
        if let ref = rows[i].asrReference, let hyp = rows[i].asrText {
            rows[i].wer = WER.score(reference: ref, hypothesis: hyp)
        }
    }
    let loaded = try EvalCase.load(args[2])
    var seen = Set<String>(), dupes = Set<String>()
    for c in loaded where !seen.insert(c.id).inserted { dupes.insert(c.id) }
    if !dupes.isEmpty {
        FileHandle.standardError.write(Data("warning: duplicate case ids: \(dupes.sorted().joined(separator: ", "))\n".utf8))
    }
    let cases = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let scores = rows.compactMap { row in cases[row.id].map { Scorer.score(evalCase: $0, row: row) } }
    let fails = scores.filter { !$0.mechanicalPass }
    print("total \(scores.count), pass \(scores.count - fails.count), fail \(fails.count)")

    // Per-target roll-up: pass rate + latency (median/p90 ms) per stage.
    let agg = Scorer.aggregate(scores: scores, rows: rows)
    for target in agg.keys.sorted() {
        guard let a = agg[target] else { continue }
        let lat = a.latency.keys.sorted().map { "\($0) \(a.latency[$0]!.median)/\(a.latency[$0]!.p90)" }.joined(separator: "  ")
        print("  [\(target)] pass \(a.pass)/\(a.total)  latency(med/p90 ms): \(lat)")
    }

    // ASR-vs-cleanup attribution split.
    let asr = fails.filter { $0.attribution == "asr" }.count
    let cleanup = fails.filter { $0.attribution == "cleanup" }.count
    if asr + cleanup > 0 { print("  attribution: asr \(asr), cleanup \(cleanup)") }

    for f in fails {
        print("  FAIL [\(f.target)] \(f.id): \(f.reasons.joined(separator: "; ")) (\(f.attribution ?? "-"))")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
