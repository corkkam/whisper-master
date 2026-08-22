import Foundation
import EvalScoreKit

// Usage: eval-score <results.json> <cases.jsonl> [--json]
//
// Reads the runner's results + the cases, computes WER for audio rows, scores
// each row, and prints a pass/fail summary plus the continuous metrics
// (retention, edit rate, novel words, ms/word, reference WER). Cheap and
// re-runnable — tweak rules and re-run without touching the expensive runner.
//
// `--json` emits the same roll-up as one machine-readable object, which is what
// a CI step or the dashboard ingest should read rather than parsing this text.
let args = CommandLine.arguments
let wantsJSON = args.contains("--json")
let positional = args.dropFirst().filter { !$0.hasPrefix("--") }
guard positional.count >= 2 else {
    FileHandle.standardError.write(Data("usage: eval-score <results.json> <cases.jsonl> [--json]\n".utf8))
    exit(2)
}

func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
func f2(_ v: Double) -> String { String(format: "%.2f", v) }

do {
    let rowsData = try Data(contentsOf: URL(fileURLWithPath: positional[0]))
    var rows = try JSONDecoder().decode([ResultRow].self, from: rowsData)
    for i in rows.indices where rows[i].inputKind == "audio" {
        if let ref = rows[i].asrReference, let hyp = rows[i].asrText {
            rows[i].wer = WER.score(reference: ref, hypothesis: hyp)
        }
    }
    let loaded = try EvalCase.load(positional[1])
    var seen = Set<String>(), dupes = Set<String>()
    for c in loaded where !seen.insert(c.id).inserted { dupes.insert(c.id) }
    if !dupes.isEmpty {
        FileHandle.standardError.write(Data("warning: duplicate case ids: \(dupes.sorted().joined(separator: ", "))\n".utf8))
    }
    let cases = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let scores = rows.compactMap { row in cases[row.id].map { Scorer.score(evalCase: $0, row: row) } }
    let fails = scores.filter { !$0.mechanicalPass }
    let agg = Scorer.aggregate(scores: scores, rows: rows)
    let byCat = Scorer.aggregateByCategory(scores: scores)

    if wantsJSON {
        var targets: [String: Any] = [:]
        for (t, a) in agg {
            targets[t] = [
                "pass": a.pass, "total": a.total,
                "weighted_pass": a.weightedPass, "weighted_total": a.weightedTotal,
                "guard_fallback_rate": a.guardFallbackRate, "no_op_rows": a.noOpRows,
                "retention": ["median": a.retention.median, "worst": a.retention.worst],
                "edit_rate": ["median": a.editRate.median, "worst": a.editRate.worst],
                "novel_word_rate": ["median": a.novelWordRate.median, "worst": a.novelWordRate.worst],
                "ms_per_word": ["median": a.msPerWord.median, "p90": a.msPerWord.p90],
                "reference_wer": ["median": a.referenceWER.median, "worst": a.referenceWER.worst,
                                  "count": a.referenceWER.count],
                "latency_ms": a.latency.mapValues { ["median": $0.median, "p90": $0.p90, "p99": $0.p99] },
            ]
        }
        let out: [String: Any] = [
            "total": scores.count, "pass": scores.count - fails.count, "fail": fails.count,
            "targets": targets,
            "categories": byCat.mapValues { ["pass": $0.pass, "total": $0.total] },
            "failures": fails.map { ["id": $0.id, "target": $0.target, "category": $0.category,
                                     "reasons": $0.reasons, "attribution": $0.attribution ?? ""] },
        ]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(fails.isEmpty ? 0 : 0)  // scoring is a report, not a gate
    }

    print("total \(scores.count), pass \(scores.count - fails.count), fail \(fails.count)")

    // Per-target roll-up.
    for target in agg.keys.sorted() {
        guard let a = agg[target] else { continue }
        let lat = a.latency.keys.sorted()
            .map { "\($0) \(a.latency[$0]!.median)/\(a.latency[$0]!.p90)/\(a.latency[$0]!.p99)" }
            .joined(separator: "  ")
        print("  [\(target)] pass \(a.pass)/\(a.total)  weighted \(f2(a.weightedPass))/\(f2(a.weightedTotal))")
        print("      latency(med/p90/p99 ms): \(lat)   ms/word med \(f2(a.msPerWord.median))")
        print("      retention med \(f2(a.retention.median)) worst \(f2(a.retention.worst))"
            + "   edit med \(f2(a.editRate.median)) worst \(f2(a.editRate.worst))")
        print("      novel-word med \(pct(a.novelWordRate.median)) worst \(pct(a.novelWordRate.worst))"
            + "   guard fallback \(pct(a.guardFallbackRate))   no-op rows \(a.noOpRows)/\(a.total)")
        if a.referenceWER.count > 0 {
            print("      reference WER med \(pct(a.referenceWER.median)) worst \(pct(a.referenceWER.worst))"
                + " (\(a.referenceWER.count) cases carry a reference)")
        }
    }

    // Per-category pass rate — a suite total can stay green while one category
    // goes fully red, and this is where that shows.
    let cats = byCat.keys.sorted { (byCat[$0]!.total - byCat[$0]!.pass) > (byCat[$1]!.total - byCat[$1]!.pass) }
    print("  by category:")
    for c in cats {
        guard let a = byCat[c] else { continue }
        let mark = a.pass == a.total ? "  " : "! "
        print("    \(mark)\(c.padding(toLength: 14, withPad: " ", startingAt: 0)) \(a.pass)/\(a.total)"
            + "  weight ×\(f2(Scorer.weight(for: c)))")
    }

    // ASR-vs-cleanup attribution split.
    let asr = fails.filter { $0.attribution == "asr" }.count
    let cleanup = fails.filter { $0.attribution == "cleanup" }.count
    if asr + cleanup > 0 { print("  attribution: asr \(asr), cleanup \(cleanup)") }

    for f in fails {
        print("  FAIL [\(f.target)] \(f.id) (\(f.category)): \(f.reasons.joined(separator: "; ")) (\(f.attribution ?? "-"))")
    }

    // Rows that satisfy every keyword rule and still look wrong. This section is
    // the point of the metrics: the long-form truncation passed its rules, and a
    // retention of 0.40 is what would have said so without anyone having thought
    // to assert the missing sentence.
    let suspicious = scores.filter { s in
        guard s.mechanicalPass, s.metrics.inputWords >= 8 else { return false }
        return s.metrics.retention < 0.75 || s.metrics.retention > 1.6
            || !s.metrics.novelWords.isEmpty
    }
    if !suspicious.isEmpty {
        print("  passed the rules, worth a look (\(suspicious.count)):")
        for s in suspicious.sorted(by: { $0.metrics.retention < $1.metrics.retention }) {
            var why = "retention \(f2(s.metrics.retention))"
            if !s.metrics.novelWords.isEmpty {
                why += ", novel: \(s.metrics.novelWords.prefix(6).joined(separator: " "))"
            }
            print("    ? [\(s.target)] \(s.id): \(why)")
        }
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
