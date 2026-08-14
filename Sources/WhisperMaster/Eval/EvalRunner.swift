import Foundation
@preconcurrency import AVFoundation

/// Dev-only evaluation runner. Activated by `WM_EVAL_CASES=<path>`: after the
/// cleanup model is loaded, it pushes every case through the real pipeline and
/// writes per-stage outputs, guard verdicts, and latency to `results.json`.
///
/// - **Text cases** inject at the deterministic stage (the same passes as
///   `DictationViewModel`), then run the light and polish LLM modes with the real
///   `CleanupFaithfulnessGuard`.
/// - **Audio cases** inject at the top: the file is replayed through the real
///   `FluidAudioStreamingTranscriber` (chunked exactly like the live mic), and the
///   ASR text + reference are recorded (WER is computed later by `eval-score`),
///   then the same deterministic + LLM stages run.
///
/// Launch via LaunchServices (`open`), passing env through `launchctl setenv` —
/// a directly-exec'd bundle fails TCC's Info.plist lookup and the mesh Bluetooth
/// scan hard-crashes.
enum EvalRunner {
    private struct Item {
        let id, det, inputKind: String
        let asrText, asrReference: String?
        let asrMs: Int?
        let targets: [String]
    }

    static func runIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard let casesPath = env["WM_EVAL_CASES"] else { return }
        let outPath = env["WM_EVAL_OUT"]
            ?? (casesPath as NSString).deletingLastPathComponent + "/results.json"

        await MlxCleanupService.shared.prepare(configuration: .init(directory: CleanupModel.directory))
        guard await MlxCleanupService.shared.isReady else {
            Log.modelPrep.error("EvalRunner: cleanup model not ready; aborting")
            return
        }

        let items = await buildItems(casesPath)

        // LLM stage grouped by target so the system-prompt KV cache stays primed
        // within a target (alternating modes re-primes every call → wrong latency).
        var rows: [[String: Any]] = []
        let requested = Set(items.flatMap(\.targets))
        let targets = CleanupTarget.allCases.filter { requested.contains($0.rawValue) }
        for target in targets {
            let prompt = target.prompt
            for item in items where item.targets.contains(target.rawValue) {
                let start = Date()
                let llm = await MlxCleanupService.shared.clean(item.det, systemPrompt: prompt) ?? item.det
                let llmMs = Int(Date().timeIntervalSince(start) * 1000)
                let accepted = CleanupFaithfulnessGuard.accept(
                    original: item.det, cleaned: llm, allowRephrase: target.allowsRephrase)
                var latency: [String: Int] = ["deterministic": 0, "llm": llmMs, "total": llmMs]
                if let asrMs = item.asrMs { latency["asr"] = asrMs; latency["total"] = asrMs + llmMs }
                var row: [String: Any] = [
                    "id": item.id, "target": target.rawValue, "input_kind": item.inputKind,
                    "deterministic": item.det, "llm_output": accepted ? llm : item.det,
                    "guard": ["accepted": accepted], "wer": NSNull(), "latency_ms": latency,
                ]
                if item.inputKind == "audio" {
                    row["asr_text"] = item.asrText ?? ""
                    row["asr_reference"] = item.asrReference ?? ""
                }
                rows.append(row)
            }
        }
        writeJSON(rows, to: outPath)
        Log.modelPrep.notice("EvalRunner wrote \(rows.count) rows to \(outPath, privacy: .public)")
    }

    /// Resolve each case to its deterministic input, running ASR for audio cases.
    private static func buildItems(_ casesPath: String) async -> [Item] {
        var transcriber: FluidAudioStreamingTranscriber?
        var items: [Item] = []
        for c in loadCases(casesPath) {
            let id = c["id"] as? String ?? ""
            let targets = c["targets"] as? [String] ?? ["light", "polish"]
            let input = (c["input"] as? [String: Any]) ?? wrap(c["input"])
            if let text = input?["text"] as? String {
                items.append(Item(id: id, det: deterministic(text), inputKind: "text",
                                  asrText: nil, asrReference: nil, asrMs: nil, targets: targets))
            } else if let audioPath = input?["audio"] as? String {
                if transcriber == nil {
                    let t = FluidAudioStreamingTranscriber()
                    do { try await t.prepareModels { _ in } } catch {
                        Log.modelPrep.error("EvalRunner: ASR prepare failed: \(error.localizedDescription, privacy: .public)")
                        continue
                    }
                    transcriber = t
                }
                guard let t = transcriber, let (asr, ms) = await transcribe(audioPath, with: t) else { continue }
                items.append(Item(id: id, det: deterministic(asr), inputKind: "audio",
                                  asrText: asr, asrReference: c["asr_reference"] as? String ?? "",
                                  asrMs: ms, targets: targets))
            }
        }
        return items
    }

    /// Replay a file through the transcriber in ~100 ms chunks, the way the live
    /// mic tap does (mirrors `AudioReplayTests`). Returns the final ASR text + ms.
    private static func transcribe(
        _ path: String, with transcriber: FluidAudioStreamingTranscriber
    ) async -> (String, Int)? {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate * 0.1)
        let start = Date()
        do {
            try await transcriber.start { _ in }
            while file.framePosition < file.length {
                let remaining = AVAudioFrameCount(file.length - file.framePosition)
                let n = min(chunk, remaining)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { break }
                try file.read(into: buffer, frameCount: n)
                try await transcriber.append(buffer)
            }
            let text = try await transcriber.stop()
            return (text, Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            return nil
        }
    }

    /// Mirror `DictationViewModel`'s non-LLM pipeline order exactly. Empty glossary
    /// and always-on ITN/filler removal so the eval is reproducible.
    private static func deterministic(_ raw: String) -> String {
        let spaced = TranscriptSpacingRepair.repair(raw)
        let corrected = SelfCorrectionCollapser.collapse(spaced)
        let itn = DeterministicITN.normalize(corrected)
        let deFillered = FillerWordFilter.clean(itn)
        return VocabularyPostProcessor.apply(deFillered, glossary: [])
    }

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
