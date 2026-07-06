# Dictation Evaluation Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. (Subagent-driven execution is intentionally NOT used for this project — no sub-agents.)

**Goal:** Build a quality-first evaluation engine that runs test cases through the real on-device pipeline (Parakeet ASR + deterministic passes + MLX cleanup), scores them, and hands the outputs to Claude Code to judge — measuring faithfulness, quality, WER, and per-stage latency.

**Architecture:** An in-app Swift runner (`WM_EVAL_CASES`) grades every stage of the real pipeline and dumps `results.json`, using the **real** `CleanupFaithfulnessGuard` (no port). A standalone Swift CLI (`eval-score`) reads `results.json` + `cases.jsonl` and does objective scoring (keyword rules, WER, attribution, latency aggregation). Claude Code reads the results and writes `judgment.md`. Audio generation is a small shell script (tool glue). Everything generated/downloaded lives in a git-ignored scratch dir.

**Tech Stack:** Swift (durable logic — in-app runner + `eval-score` CLI, pure SwiftPM library, no external deps), `bash` + macOS `say` + `ffmpeg` + `curl` (audio glue), Claude Code (judge).

## Global Constraints

- **Language split (locked by decision):** durable logic (schema, WER, scorer) is **Swift**; the in-app runner is **Swift** (reuses the real `CleanupFaithfulnessGuard` — the ONE guard, no Python/Go port, no drift); disposable glue (audio-gen, ad-hoc analysis) is **bash/Python one-liners**. Do not reintroduce a ported guard.
- **`eval-score` has no external dependencies** — a pure SwiftPM library + thin executable, independent of the `WhisperMaster` app target (so it never pulls MLX/Sparkle).
- **Generated/downloaded audio is git-ignored scratch** under `eval/text-cleanup/.eval-scratch/`. Never commit `results.json`, TTS output, augmented clips, or the Common Voice slice. Only the tiny existing committed fixtures stay in git.
- **Grade the real pipeline**, never Ollama. Judged outputs come from the in-app MLX runner.
- **Commit style:** no `Co-Authored-By` trailer, no emojis in commit messages.
- **Targets abstraction:** `light` + `polish` now; the engine is `cases × targets`. Adding `slack`/`email`/`code` later must require no runner/scorer change.
- **Latency is graded**, not just logged: per-stage (`asr`, `deterministic`, `llm`, `total`) in `results.json`; the report shows median/p90 and the light-vs-polish delta.

---

## File Structure

| File | Responsibility |
|---|---|
| `eval/text-cleanup/EvalScore/Case.swift` | Case schema: load + normalize `cases.jsonl` (pure) |
| `eval/text-cleanup/EvalScore/WER.swift` | Word error rate + normalization (pure) |
| `eval/text-cleanup/EvalScore/Scorer.swift` | Keyword rules + WER + attribution + latency aggregation (pure) |
| `eval/text-cleanup/EvalScoreCLI/main.swift` | Thin CLI: read `results.json` + `cases.jsonl` → print report |
| `eval/text-cleanup/EvalScoreTests/*.swift` | Unit tests for the above |
| `Package.swift` | Add `EvalScoreKit` lib, `eval-score` exe, `EvalScoreKitTests` |
| `Sources/WhisperMaster/Eval/EvalRunner.swift` | In-app: `WM_EVAL_CASES` runner over the real pipeline (real guard) |
| `Sources/WhisperMaster/App/AppDelegate.swift` | Kick `EvalRunner` at launch when env var set |
| `eval/text-cleanup/make_audio.sh` | bash glue: TTS + augmentation + Common Voice → scratch + manifest |
| `eval/text-cleanup/cases.jsonl` | Cases (generalized schema, committed) |
| `eval/text-cleanup/README.md`, `.gitignore` | Run instructions; ignore scratch |

**Removed:** `eval/text-cleanup/schema.py` (superseded by `Case.swift`). The legacy Ollama harness (`run.py`, `guard.py`) is left untouched as historical, not extended.

TDD applies to `EvalScoreKit` (pure Swift, runs under `swift test`). The in-app `EvalRunner` runs MLX/Metal so it can't run under `swift test`; it's verified by running the app and inspecting `results.json`.

**`results.json` row shape (stable contract across runner + scorer):**
```jsonc
{ "id": str, "target": "light"|"polish", "input_kind": "text"|"audio",
  "asr_text": str?, "asr_reference": str?,     // audio only
  "deterministic": str, "llm_output": str,
  "guard": { "accepted": bool },
  "latency_ms": { "asr": int?, "deterministic": int, "llm": int, "total": int } }
```

---

## PHASE 1 — Text-cleanup loop (Swift `eval-score` + in-app runner)

### Task 1: `EvalScoreKit` — schema, WER, scorer (Swift, TDD)

**Files:**
- Create: `eval/text-cleanup/EvalScore/{Case,WER,Scorer}.swift`
- Create: `eval/text-cleanup/EvalScoreCLI/main.swift`
- Create: `eval/text-cleanup/EvalScoreTests/{WERTests,ScorerTests,CaseTests}.swift`
- Modify: `Package.swift` (add targets)
- Delete: `eval/text-cleanup/schema.py`, `eval/text-cleanup/tests/test_schema.py`

**Interfaces (Produces):**
- `struct EvalCase { id, category: String; inputText, inputAudio, reference, asrReference: String?; targets: [String]; mustContain, mustNotContain: [String] }` + `static func load(_ path: String) throws -> [EvalCase]`.
- `enum WER { static func score(reference: String, hypothesis: String) -> Double }`.
- `struct ResultRow: Decodable { id, target, inputKind: String; asrText, asrReference: String?; llmOutput: String; guard: GuardVerdict; latencyMs: [String:Int] }` and `enum Scorer { static func score(case: EvalCase, row: ResultRow) -> RunScore; static func aggregate(_ scores: [RunScore], _ rows: [ResultRow]) -> Aggregate }`.

- [ ] **Step 1: Add targets to `Package.swift`**

Insert into `targets:` array (after the test target):

```swift
.target(name: "EvalScoreKit", path: "eval/text-cleanup/EvalScore"),
.executableTarget(name: "eval-score", dependencies: ["EvalScoreKit"],
                  path: "eval/text-cleanup/EvalScoreCLI"),
.testTarget(name: "EvalScoreKitTests", dependencies: ["EvalScoreKit"],
            path: "eval/text-cleanup/EvalScoreTests"),
```

- [ ] **Step 2: Write the failing WER test**

```swift
// eval/text-cleanup/EvalScoreTests/WERTests.swift
import XCTest
@testable import EvalScoreKit

final class WERTests: XCTestCase {
    func testIdenticalIsZero() { XCTAssertEqual(WER.score(reference: "hello world", hypothesis: "Hello, world!"), 0.0) }
    func testOneSubstitution() { XCTAssertEqual(WER.score(reference: "the cat sat", hypothesis: "the dog sat"), 1.0/3.0, accuracy: 1e-9) }
    func testDeletion() { XCTAssertEqual(WER.score(reference: "a b c d", hypothesis: "a b d"), 1.0/4.0, accuracy: 1e-9) }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter WERTests 2>&1 | tail -5`
Expected: FAIL (`no such module 'EvalScoreKit'` / undefined `WER`)

- [ ] **Step 4: Implement `WER.swift`**

```swift
// eval/text-cleanup/EvalScore/WER.swift
import Foundation

/// Word error rate with light normalization (lowercase, keep [a-z0-9']).
public enum WER {
    public static func normalize(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }
    public static func score(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference), h = normalize(hypothesis)
        if r.isEmpty { return h.isEmpty ? 0.0 : 1.0 }
        var prev = Array(0...h.count)
        for (i, rw) in r.enumerated() {
            var cur = [i + 1]
            for (j, hw) in h.enumerated() {
                let cost = rw == hw ? 0 : 1
                cur.append(Swift.min(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}
```

- [ ] **Step 5: Run WER test to verify pass**

Run: `swift test --filter WERTests 2>&1 | tail -5`
Expected: PASS (3 tests)

- [ ] **Step 6: Write the failing `Case` test**

```swift
// eval/text-cleanup/EvalScoreTests/CaseTests.swift
import XCTest
@testable import EvalScoreKit

final class CaseTests: XCTestCase {
    func testLegacyStringInputWraps() throws {
        let c = try EvalCase.decode(#"{"id":"a","category":"numbers","input":"hello","must_contain":["hello"]}"#)
        XCTAssertEqual(c.inputText, "hello")
        XCTAssertNil(c.inputAudio)
        XCTAssertEqual(c.targets, ["light", "polish"])
    }
    func testNewSchemaPassthrough() throws {
        let c = try EvalCase.decode(#"{"id":"b","category":"grammar","input":{"text":"x"},"targets":["polish"],"reference":"X."}"#)
        XCTAssertEqual(c.inputText, "x")
        XCTAssertEqual(c.targets, ["polish"])
        XCTAssertEqual(c.reference, "X.")
    }
    func testAudioRequiresAsrReference() {
        XCTAssertThrowsError(try EvalCase.decode(#"{"id":"c","category":"x","input":{"audio":"f.m4a"}}"#))
    }
}
```

- [ ] **Step 7: Run to verify it fails, then implement `Case.swift`**

```swift
// eval/text-cleanup/EvalScore/Case.swift
import Foundation

public struct EvalCase {
    public let id, category: String
    public let inputText, inputAudio, reference, asrReference: String?
    public let targets, mustContain, mustNotContain: [String]

    public static func decode(_ line: String) throws -> EvalCase {
        guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = obj["id"] as? String else {
            throw NSError(domain: "EvalCase", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing id"])
        }
        var text: String?, audio: String?
        if let s = obj["input"] as? String { text = s }
        else if let d = obj["input"] as? [String: Any] { text = d["text"] as? String; audio = d["audio"] as? String }
        if text == nil, audio == nil {
            throw NSError(domain: "EvalCase", code: 2, userInfo: [NSLocalizedDescriptionKey: "input must be text or audio"])
        }
        let asrRef = obj["asr_reference"] as? String
        if audio != nil, (asrRef ?? "").isEmpty {
            throw NSError(domain: "EvalCase", code: 3, userInfo: [NSLocalizedDescriptionKey: "audio case needs asr_reference"])
        }
        return EvalCase(
            id: id, category: obj["category"] as? String ?? "uncategorized",
            inputText: text, inputAudio: audio, reference: obj["reference"] as? String,
            asrReference: asrRef, targets: obj["targets"] as? [String] ?? ["light", "polish"],
            mustContain: obj["must_contain"] as? [String] ?? [],
            mustNotContain: obj["must_not_contain"] as? [String] ?? [])
    }

    public static func load(_ path: String) throws -> [EvalCase] {
        try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decode($0) }
    }
}
```

Run: `swift test --filter CaseTests 2>&1 | tail -5` → PASS (3 tests).

- [ ] **Step 8: Write the failing `Scorer` test, then implement `Scorer.swift`**

```swift
// eval/text-cleanup/EvalScoreTests/ScorerTests.swift
import XCTest
@testable import EvalScoreKit

final class ScorerTests: XCTestCase {
    let c = try! EvalCase.decode(#"{"id":"x","category":"numbers","input":{"text":"twenty five"},"must_contain":["$25"],"must_not_contain":["25 dollars"]}"#)
    func row(_ out: String, wer: Double? = nil) -> ResultRow {
        ResultRow(id: "x", target: "light", inputKind: wer == nil ? "text" : "audio",
                  asrText: nil, asrReference: nil, llmOutput: out,
                  guardVerdict: .init(accepted: true), latencyMs: [:], wer: wer)
    }
    func testPassWhenRulesAndGuardOK() { XCTAssertTrue(Scorer.score(evalCase: c, row: row("It is $25.")).mechanicalPass) }
    func testFailMissingMustContain() {
        let s = Scorer.score(evalCase: c, row: row("It is 25 dollars."))
        XCTAssertFalse(s.mechanicalPass)
        XCTAssertEqual(s.attribution, "cleanup")
    }
    func testHighWerAttributesAsr() {
        XCTAssertEqual(Scorer.score(evalCase: c, row: row("wrong", wer: 0.5)).attribution, "asr")
    }
}
```

```swift
// eval/text-cleanup/EvalScore/Scorer.swift
import Foundation

public struct GuardVerdict: Decodable { public let accepted: Bool
    public init(accepted: Bool) { self.accepted = accepted } }

public struct ResultRow: Decodable {
    public let id, target, inputKind: String
    public let asrText, asrReference: String?
    public let llmOutput: String
    public let guardVerdict: GuardVerdict
    public let latencyMs: [String: Int]
    public var wer: Double?
    enum CodingKeys: String, CodingKey {
        case id, target, inputKind = "input_kind", asrText = "asr_text",
             asrReference = "asr_reference", llmOutput = "llm_output",
             guardVerdict = "guard", latencyMs = "latency_ms", wer
    }
    public init(id: String, target: String, inputKind: String, asrText: String?, asrReference: String?,
                llmOutput: String, guardVerdict: GuardVerdict, latencyMs: [String: Int], wer: Double?) {
        self.id = id; self.target = target; self.inputKind = inputKind; self.asrText = asrText
        self.asrReference = asrReference; self.llmOutput = llmOutput; self.guardVerdict = guardVerdict
        self.latencyMs = latencyMs; self.wer = wer
    }
}

public struct RunScore { public let id, target: String; public let mechanicalPass: Bool
    public let reasons: [String]; public let attribution: String? }

public enum Scorer {
    public static let werFailThreshold = 0.15
    public static func score(evalCase: EvalCase, row: ResultRow) -> RunScore {
        var reasons: [String] = []
        let low = row.llmOutput.lowercased()
        for t in evalCase.mustContain where !low.contains(t.lowercased()) { reasons.append("missing '\(t)'") }
        for t in evalCase.mustNotContain where low.contains(t.lowercased()) { reasons.append("forbidden '\(t)'") }
        if !row.guardVerdict.accepted { reasons.append("guard rejected") }
        var attribution: String?
        if let w = row.wer, w > werFailThreshold { attribution = "asr"; reasons.append("asr wer \(Int(w * 100))%") }
        else if !reasons.isEmpty { attribution = "cleanup" }
        return RunScore(id: evalCase.id, target: row.target, mechanicalPass: reasons.isEmpty,
                        reasons: reasons, attribution: attribution)
    }
}
```

Run: `swift test --filter ScorerTests 2>&1 | tail -5` → PASS (3 tests).

- [ ] **Step 9: Write the CLI + delete the Python schema**

```swift
// eval/text-cleanup/EvalScoreCLI/main.swift
import Foundation
import EvalScoreKit

// Usage: eval-score <results.json> <cases.jsonl>
let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write(Data("usage: eval-score <results.json> <cases.jsonl>\n".utf8)); exit(2) }
let rowsData = try Data(contentsOf: URL(fileURLWithPath: args[1]))
var rows = try JSONDecoder().decode([ResultRow].self, from: rowsData)
for i in rows.indices where rows[i].inputKind == "audio" {
    if let ref = rows[i].asrReference, let hyp = rows[i].asrText { rows[i].wer = WER.score(reference: ref, hypothesis: hyp) }
}
let cases = Dictionary(uniqueKeysWithValues: try EvalCase.load(args[2]).map { ($0.id, $0) })
let scores = rows.compactMap { r in cases[r.id].map { Scorer.score(evalCase: $0, row: r) } }
let fails = scores.filter { !$0.mechanicalPass }
print("total \(scores.count), pass \(scores.count - fails.count), fail \(fails.count)")
for f in fails { print("  FAIL [\(f.target)] \(f.id): \(f.reasons.joined(separator: "; ")) (\(f.attribution ?? "-"))") }
```

```bash
git rm eval/text-cleanup/schema.py eval/text-cleanup/tests/test_schema.py
```

- [ ] **Step 10: Build the CLI + run all tests**

Run: `swift build --target eval-score 2>&1 | grep -E 'error:|Compiling|Build complete'; swift test --filter EvalScoreKitTests 2>&1 | grep -E 'Executed|error:'`
Expected: build succeeds; `Executed 9 tests` (3 WER + 3 Case + 3 Scorer), 0 failures.

- [ ] **Step 11: Commit**

```bash
git add Package.swift eval/text-cleanup/EvalScore eval/text-cleanup/EvalScoreCLI eval/text-cleanup/EvalScoreTests
git commit -m "eval: EvalScoreKit (schema, WER, scorer) as a Swift CLI"
```

---

### Task 2: In-app eval runner (text path, real guard)

**Files:**
- Create: `Sources/WhisperMaster/Eval/EvalRunner.swift`
- Modify: `Sources/WhisperMaster/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `MlxCleanupService.shared.clean(_:systemPrompt:)`, `CleanupPrompt.resolved(grammarPolish:)`, the deterministic passes as ordered in `DictationViewModel.stopRecording` (`TranscriptSpacingRepair.repair`, `DeterministicITN.normalize`, `FillerWordFilter.clean`, `VocabularyPostProcessor.apply`), the **real** `CleanupFaithfulnessGuard.accept(original:cleaned:allowRephrase:)`.
- Produces: `enum EvalRunner { static func runIfRequested() async }` — no-op unless `WM_EVAL_CASES` set; writes `results.json` in the row shape above.

- [ ] **Step 1: Implement `EvalRunner` (text path)** — same structure as the previous plan revision's runner, but the deterministic helper must match `DictationViewModel` exactly; verify each API name against `DictationViewModel.stopRecording` before finalizing, do not invent APIs. Emit rows with `guard.accepted` from the real guard and `latency_ms.llm` timed around `clean`.

- [ ] **Step 2: Wire launch hook in `AppDelegate.applicationDidFinishLaunching`** (after `viewModel.prepareDefaultEngineOnLaunch()`):

```swift
if ProcessInfo.processInfo.environment["WM_EVAL_CASES"] != nil {
    Task { await EvalRunner.runIfRequested() }
}
```

- [ ] **Step 3: Build** — `swift build 2>&1 | grep -E 'error:|Build complete'` → `Build complete!`
- [ ] **Step 4: Run over text cases** — `bash Scripts/bundle.sh`; `WM_EVAL_CASES=… WM_EVAL_OUT=….eval-scratch/results.json open "build/Whisper Master.app"`; wait ~2 min; verify `results.json` has `84 × targets` rows with `llm_output`, `guard`, `latency_ms`.
- [ ] **Step 5: Score** — `swift run eval-score eval/text-cleanup/.eval-scratch/results.json eval/text-cleanup/cases.jsonl` prints pass/fail.
- [ ] **Step 6: Commit** — `git commit -m "eval: in-app runner grading the real pipeline (text path)"`

---

### Task 3: Grammar/polish cases + `.gitignore` + README

- [ ] **Step 1: Append grammar cases** to `cases.jsonl` (5 rows: subject-verb agreement, run-on, past tense, a faithfulness question polish must not answer, self-correction+number). Each on its own line, generalized schema.
- [ ] **Step 2: Verify** `swift run eval-score` still loads (no decode error) and `EvalCase.load` count increased by 5.
- [ ] **Step 3: `.gitignore`** — add `.eval-scratch/`, `results.json`.
- [ ] **Step 4: README** — the text-loop commands + `swift test --filter EvalScoreKitTests` + `rm -rf .eval-scratch`.
- [ ] **Step 5: First judgment** — Claude Code reads `results.json`, writes `judgment.md` (faithfulness + quality per target, light-vs-polish, latency, recommendations).
- [ ] **Step 6: Commit** — `git commit -m "eval: grammar cases, gitignore, README, first judgment"`

---

## PHASE 2 — Audio layer

### Task 4: Audio generation (`make_audio.sh`, bash glue)

**Files:** Create `eval/text-cleanup/make_audio.sh`

- [ ] **Step 1: TTS from text cases** — for each text case, `say -o <id>.aiff "<text>"` then `ffmpeg -i <id>.aiff <id>.m4a` into `.eval-scratch/audio/tts/`; append an audio case (`input.audio`, `asr_reference` = the text) to `.eval-scratch/audio_cases.jsonl`.
- [ ] **Step 2: Augmentation** — noise mix at SNR levels and a Bluetooth-HFP variant (`ffmpeg` `aformat=…mono,aresample=8000,highpass=f=300,lowpass=f=3400`); each variant appends an audio case with `asr_reference` = its source clip's.
- [ ] **Step 3: Common Voice slice** — `curl` a small CC0 slice into scratch; append audio cases from its TSV transcripts.
- [ ] **Step 4: Run + sanity** — `brew list ffmpeg || brew install ffmpeg`; `bash make_audio.sh`; confirm `.eval-scratch/audio_cases.jsonl` populated and clips exist.
- [ ] **Step 5: Commit** — `git commit -m "eval: audio generation glue (TTS, augmentation, Common Voice)"`

---

### Task 5: Eval runner — audio path + per-stage latency

**Files:** Modify `Sources/WhisperMaster/Eval/EvalRunner.swift`

- [ ] **Step 1: Add audio branch** — for `input.audio` cases, feed the file through `FluidAudioStreamingTranscriber` exactly as `Tests/WhisperMasterTests/AudioReplayTests.swift` does (do not invent a decode path); time the ASR; run `deterministic → targets` on the ASR text; emit rows with `asr_text`, `asr_reference`, and `latency_ms.asr`. Leave `wer` null (the scorer computes it).
- [ ] **Step 2: Build** — `swift build` → `Build complete!`
- [ ] **Step 3: Run over audio cases** — `WM_EVAL_CASES=….eval-scratch/audio_cases.jsonl … open` → `results_audio.json` with `asr_text` present.
- [ ] **Step 4: Commit** — `git commit -m "eval: runner audio path (ASR text, references, per-stage latency)"`

---

### Task 6: Full audio loop + attribution + latency report

**Files:** Modify `eval/text-cleanup/EvalScoreCLI/main.swift` (add latency aggregation + attribution summary to the printed report), `README.md`

- [ ] **Step 1: Extend the CLI report** — add median/p90 per stage per target and the light-vs-polish latency delta; group failures by `attribution` (asr vs cleanup). (Aggregation lives in `Scorer.aggregate`; add it + a test.)
- [ ] **Step 2: Run the full audio loop** — `swift run eval-score …/results_audio.json cases-plus-audio` prints pass rates + latency + attribution.
- [ ] **Step 3: Judgment + README** — Claude Code updates `judgment.md` with ASR-vs-cleanup attribution and the WER/latency tables; README gets the audio-loop commands.
- [ ] **Step 4: Commit** — `git commit -m "eval: WER attribution + latency report, full audio loop"`

---

## Self-Review notes (reconciled)

- **Language split honored:** all durable logic (Case/WER/Scorer) + runner are Swift; the runner reuses the real guard (no port); only audio-gen is bash. `schema.py` removed.
- **Spec coverage:** stages/attribution (Tasks 2, 5, 6); real pipeline + real guard (Task 2); text + grammar cases (Tasks 1, 3); audio 3 sources + augmentation (Task 4); WER (Task 1); scorer (Task 1); Claude judge (Tasks 3, 6 — human/Claude step); targets abstraction (Task 2 loops `targets`); latency graded (Tasks 1, 2, 5, 6); repo hygiene (Task 3); capped loop (README process).
- **Deferred, per spec:** app-format targets (slack/email/code) — schema + `targets` already support them.
- **Type consistency:** the `results.json` row shape and `ResultRow` `CodingKeys` match across Tasks 1, 2, 5, 6.
- **Manual gate:** the "capped loop (3 rounds)" is an operator process documented in the README, not code.
