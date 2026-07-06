import Foundation

/// Dev-only evaluation runner. Activated by `WM_EVAL_CASES=<path>`: after the
/// cleanup model is loaded, it pushes every **text** case through the real
/// pipeline (the same deterministic passes as `DictationViewModel`, then the
/// light and polish LLM modes with the real `CleanupFaithfulnessGuard`) and
/// writes per-stage outputs, guard verdicts, and latency to `results.json`.
///
/// This is how the eval grades what actually ships. Audio cases are handled in a
/// later task; here they are skipped. Output path is `WM_EVAL_OUT` or a
/// `results.json` next to the cases file.
enum EvalRunner {
    static func runIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard let casesPath = env["WM_EVAL_CASES"] else { return }
        let outPath = env["WM_EVAL_OUT"]
            ?? (casesPath as NSString).deletingLastPathComponent + "/results.json"

        // Grade the real model — load it explicitly so the run doesn't depend on
        // the user's smart-cleanup toggle being on.
        await MlxCleanupService.shared.prepare(
            configuration: .init(directory: CleanupModel.directory))
        guard await MlxCleanupService.shared.isReady else {
            Log.modelPrep.error("EvalRunner: cleanup model not ready; aborting")
            return
        }

        // Precompute the deterministic stage per text case (audio skipped for now).
        struct Item { let id: String; let det: String; let targets: [String] }
        var items: [Item] = []
        for c in loadCases(casesPath) {
            guard let input = (c["input"] as? [String: Any]) ?? wrap(c["input"]),
                  let text = input["text"] as? String else { continue }
            items.append(Item(id: c["id"] as? String ?? "",
                              det: deterministic(text),
                              targets: c["targets"] as? [String] ?? ["light", "polish"]))
        }

        // Group by target so the system-prompt KV cache stays primed within a
        // target — alternating modes would re-prime every call and inflate the
        // measured latency past what a user (who stays in one mode) sees.
        var rows: [[String: Any]] = []
        for target in ["light", "polish"] {
            let polish = target == "polish"
            let prompt = CleanupPrompt.resolved(grammarPolish: polish)
            for item in items where item.targets.contains(target) {
                let start = Date()
                let llm = await MlxCleanupService.shared.clean(item.det, systemPrompt: prompt) ?? item.det
                let llmMs = Int(Date().timeIntervalSince(start) * 1000)
                let accepted = CleanupFaithfulnessGuard.accept(
                    original: item.det, cleaned: llm, allowRephrase: polish)
                rows.append([
                    "id": item.id, "target": target, "input_kind": "text",
                    "deterministic": item.det, "llm_output": accepted ? llm : item.det,
                    "guard": ["accepted": accepted], "wer": NSNull(),
                    "latency_ms": ["deterministic": 0, "llm": llmMs, "total": llmMs],
                ])
            }
        }
        writeJSON(rows, to: outPath)
        Log.modelPrep.notice("EvalRunner wrote \(rows.count) rows to \(outPath, privacy: .public)")
    }

    /// Mirror `DictationViewModel`'s non-LLM pipeline order exactly. Uses an empty
    /// glossary and always-on ITN/filler removal so the eval is reproducible.
    private static func deterministic(_ raw: String) -> String {
        let spaced = TranscriptSpacingRepair.repair(raw)
        let itn = DeterministicITN.normalize(spaced)
        let deFillered = FillerWordFilter.clean(itn)
        return VocabularyPostProcessor.apply(deFillered, glossary: [])
    }

    /// Accept both the new `{text: …}` shape and a legacy bare-string `input`.
    private static func wrap(_ value: Any?) -> [String: Any]? {
        (value as? String).map { ["text": $0] }
    }

    private static func loadCases(_ path: String) -> [[String: Any]] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    private static func writeJSON(_ obj: [[String: Any]], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        else { return }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
