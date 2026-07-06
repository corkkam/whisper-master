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
    let cases = Dictionary(uniqueKeysWithValues: try EvalCase.load(args[2]).map { ($0.id, $0) })
    let scores = rows.compactMap { row in cases[row.id].map { Scorer.score(evalCase: $0, row: row) } }
    let fails = scores.filter { !$0.mechanicalPass }
    print("total \(scores.count), pass \(scores.count - fails.count), fail \(fails.count)")
    for f in fails {
        print("  FAIL [\(f.target)] \(f.id): \(f.reasons.joined(separator: "; ")) (\(f.attribution ?? "-"))")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
