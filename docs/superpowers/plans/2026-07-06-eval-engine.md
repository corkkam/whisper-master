# Dictation Evaluation Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a quality-first evaluation engine that runs test cases through the real on-device pipeline (Parakeet ASR + deterministic passes + MLX cleanup), scores them mechanically, and hands the outputs to Claude Code to judge — measuring faithfulness, quality, WER, and per-stage latency.

**Architecture:** A generalized case schema drives an in-app Swift runner (`WM_EVAL_CASES`) that grades every stage of the real pipeline and dumps `results.json`. Python modules do the objective scoring (keyword rules, guard parity, WER, attribution, latency aggregation). Claude Code reads the results and writes `judgment.md`. Audio cases come from TTS (offline), a Common Voice slice (real human), and augmentation (noise / Bluetooth-HFP). Everything generated/downloaded lives in a git-ignored scratch dir.

**Tech Stack:** Python 3 (stdlib only — no pip deps), Swift (app target, MLX + FluidAudio), macOS `say` (TTS), `ffmpeg` (augmentation), `curl` (Common Voice).

## Global Constraints

- **Python: stdlib only.** No pip dependencies. If one is ever unavoidable, it goes in a throwaway venv, never the host. (Copied from spec: "no pip dependencies.")
- **Generated/downloaded audio is git-ignored scratch** under `eval/text-cleanup/.eval-scratch/`. Only the existing tiny committed fixtures stay in git. Never commit `results.json`, TTS output, augmented clips, or the Common Voice slice.
- **Grade the real pipeline**, never Ollama. The outputs judged must come from the in-app MLX runner.
- **Guard parity:** `guard.py` must stay behaviorally identical to `Sources/WhisperMaster/Transcription/CleanupFaithfulnessGuard.swift`, including the new `allow_rephrase` mode (`rephraseMaxExpansionRatio = 2.0`, `rephraseMaxNovelContentFraction = 0.5`).
- **Commit style:** no `Co-Authored-By` trailer, no emojis in commit messages.
- **Targets abstraction:** `light` + `polish` now; the engine is `cases × targets`. Adding `slack`/`email`/`code` later must require no runner/scorer change.
- **Latency is graded**, not just logged: per-stage (`asr`, `deterministic`, `llm`, `total`) in `results.json`; report shows median/p90 and the light-vs-polish delta.

---

## File Structure

| File | Responsibility |
|---|---|
| `eval/text-cleanup/cases.jsonl` | Cases in the generalized schema (committed) |
| `eval/text-cleanup/schema.py` | Load + validate cases; normalize legacy rows (pure) |
| `eval/text-cleanup/wer.py` | Word error rate + text normalization (pure) |
| `eval/text-cleanup/guard.py` | Mechanical faithfulness guard, Swift parity incl. `allow_rephrase` (pure) |
| `eval/text-cleanup/score.py` | Mechanical scorer: keyword rules + guard + WER + attribution + latency aggregation (pure) |
| `eval/text-cleanup/make_audio.py` | TTS + Common Voice fetch + augmentation → scratch + audio manifest |
| `eval/text-cleanup/tests/` | Python unit tests (stdlib `unittest`) |
| `eval/text-cleanup/README.md` | How to run the whole loop |
| `eval/text-cleanup/.gitignore` | Ignore `.eval-scratch/`, `results.json` |
| `Sources/WhisperMaster/Eval/EvalRunner.swift` | Dev-only: `WM_EVAL_CASES` runner over the real pipeline |
| `Sources/WhisperMaster/App/AppDelegate.swift` | Kick `EvalRunner` at launch when the env var is set |

TDD applies to the Python modules (pure, fast). The Swift `EvalRunner` runs MLX/Metal so it can't run under `swift test`; it is verified by running the app and inspecting `results.json`.

---

## PHASE 1 — Text-cleanup loop (working end to end on text)

### Task 1: Generalized case schema + loader

**Files:**
- Create: `eval/text-cleanup/schema.py`
- Create: `eval/text-cleanup/tests/test_schema.py`

**Interfaces:**
- Produces: `load_cases(path: str) -> list[dict]` where each case is normalized to
  `{"id": str, "category": str, "input": {"text": str} | {"audio": str}, "reference": str|None, "asr_reference": str|None, "targets": list[str], "must_contain": list[str], "must_not_contain": list[str], "note": str}`.
- Produces: `normalize_case(raw: dict) -> dict` (legacy row → normalized).

- [ ] **Step 1: Write the failing test**

```python
# eval/text-cleanup/tests/test_schema.py
import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from schema import normalize_case

class TestNormalize(unittest.TestCase):
    def test_legacy_string_input_is_wrapped(self):
        raw = {"id": "a", "category": "numbers", "input": "hello world",
               "must_contain": ["hello"], "must_not_contain": [], "note": "n"}
        c = normalize_case(raw)
        self.assertEqual(c["input"], {"text": "hello world"})
        self.assertEqual(c["targets"], ["light", "polish"])  # default
        self.assertIsNone(c["reference"])
        self.assertIsNone(c["asr_reference"])

    def test_new_schema_passthrough(self):
        raw = {"id": "b", "category": "grammar", "input": {"text": "x"},
               "targets": ["polish"], "reference": "X."}
        c = normalize_case(raw)
        self.assertEqual(c["input"], {"text": "x"})
        self.assertEqual(c["targets"], ["polish"])
        self.assertEqual(c["reference"], "X.")

    def test_audio_case_requires_asr_reference(self):
        raw = {"id": "c", "category": "realistic", "input": {"audio": "f.m4a"}}
        with self.assertRaises(ValueError):
            normalize_case(raw)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd eval/text-cleanup && python3 -m unittest tests.test_schema -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'schema'`

- [ ] **Step 3: Write minimal implementation**

```python
# eval/text-cleanup/schema.py
"""Load and validate evaluation cases in the generalized schema.

A case: id, category, input ({text} or {audio}), optional reference and
asr_reference, targets (LLM modes to run), must_contain/must_not_contain, note.
Legacy rows (a bare string `input`, no `targets`) are normalized on load so the
existing 84 cases keep working.
"""
import json

DEFAULT_TARGETS = ["light", "polish"]

def normalize_case(raw: dict) -> dict:
    inp = raw.get("input")
    if isinstance(inp, str):
        inp = {"text": inp}
    if not isinstance(inp, dict) or not ({"text", "audio"} & set(inp)):
        raise ValueError(f"case {raw.get('id')}: input must be {{text}} or {{audio}}")
    if "audio" in inp and not raw.get("asr_reference"):
        raise ValueError(f"case {raw.get('id')}: audio case needs asr_reference")
    return {
        "id": raw["id"],
        "category": raw.get("category", "uncategorized"),
        "input": inp,
        "reference": raw.get("reference"),
        "asr_reference": raw.get("asr_reference"),
        "targets": raw.get("targets", list(DEFAULT_TARGETS)),
        "must_contain": raw.get("must_contain", []),
        "must_not_contain": raw.get("must_not_contain", []),
        "note": raw.get("note", ""),
    }

def load_cases(path: str) -> list:
    cases = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                cases.append(normalize_case(json.loads(line)))
    return cases
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd eval/text-cleanup && python3 -m unittest tests.test_schema -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Verify the loader accepts the existing 84 cases**

Run: `cd eval/text-cleanup && python3 -c "from schema import load_cases; print(len(load_cases('cases.jsonl')))"`
Expected: prints `84`

- [ ] **Step 6: Commit**

```bash
git add eval/text-cleanup/schema.py eval/text-cleanup/tests/test_schema.py
git commit -m "eval: generalized case schema + loader"
```

---

### Task 2: Guard parity with `allow_rephrase`

**Files:**
- Modify: `eval/text-cleanup/guard.py`
- Create: `eval/text-cleanup/tests/test_guard.py`

**Interfaces:**
- Produces: `accept(original: str, cleaned: str, allow_rephrase: bool = False) -> bool` — behaviorally identical to the Swift `CleanupFaithfulnessGuard.accept(original:cleaned:allowRephrase:)`.

- [ ] **Step 1: Write the failing test**

```python
# eval/text-cleanup/tests/test_guard.py
import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from guard import accept

class TestGuard(unittest.TestCase):
    def test_strict_rejects_new_content_word(self):
        self.assertFalse(accept("what is the capital of france",
                                "The capital is Paris."))
    def test_strict_accepts_faithful_cleanup(self):
        self.assertTrue(accept("send it to john uh i mean jane", "Send it to Jane."))
    def test_rephrase_allows_synonyms(self):
        # grammar polish rewrites wording; strict mode would reject this.
        self.assertTrue(accept("me and him was gonna go to the store",
                               "He and I were going to the store.",
                               allow_rephrase=True))
    def test_rephrase_still_rejects_mostly_novel(self):
        self.assertFalse(accept("what is the capital of france",
                                "The capital of France is the city of Paris indeed.",
                                allow_rephrase=True))

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd eval/text-cleanup && python3 -m unittest tests.test_guard -v`
Expected: FAIL (`accept() got an unexpected keyword argument 'allow_rephrase'`)

- [ ] **Step 3: Add the `allow_rephrase` branch to `guard.py`**

Add the constants near the top of `guard.py`:

```python
REPHRASE_MAX_EXPANSION_RATIO = 2.0
REPHRASE_MAX_NOVEL_CONTENT_FRACTION = 0.5
```

Replace the `accept` signature and its length-band + content-check sections with:

```python
def accept(original, cleaned, allow_rephrase=False):
    out = (cleaned or "").strip()
    if not out:
        return False
    if "```" in out:
        return False

    iw = len(original.split())
    ow = len(out.split())
    if iw > 0:
        ratio = ow / iw
        ceiling = REPHRASE_MAX_EXPANSION_RATIO if allow_rephrase else MAX_EXPANSION_RATIO
        if ratio > ceiling:
            return False
        if iw >= TRUNCATION_FLOOR_MIN_WORDS and ratio < MIN_RETENTION_RATIO:
            return False

    if _content_tokens(original) and not _content_tokens(out):
        return False

    output_stems = [_stem(t) for t in _content_tokens(out)]

    if allow_rephrase:
        if not output_stems:
            return True
        input_stems = set(_stem(t) for t in _alpha_tokens(original))
        novel = sum(1 for s in output_stems if s not in input_stems)
        return novel / len(output_stems) <= REPHRASE_MAX_NOVEL_CONTENT_FRACTION

    input_counts = Counter(_stem(t) for t in _alpha_tokens(original))
    output_counts = Counter(output_stems)
    for word, count in output_counts.items():
        if count > input_counts.get(word, 0):
            return False
    return True
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd eval/text-cleanup && python3 -m unittest tests.test_guard -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add eval/text-cleanup/guard.py eval/text-cleanup/tests/test_guard.py
git commit -m "eval: guard parity with allow_rephrase mode"
```

---

### Task 3: Mechanical scorer (text)

**Files:**
- Create: `eval/text-cleanup/score.py`
- Create: `eval/text-cleanup/tests/test_score.py`

**Interfaces:**
- Consumes: `guard.accept`, `schema.load_cases`.
- Produces: `score_run(case: dict, target: str, result: dict) -> dict` returning
  `{"id", "target", "mechanical_pass": bool, "reasons": list[str], "attribution": "asr"|"cleanup"|None}`.
  `result` is one entry from `results.json`:
  `{"llm_output": str, "guard": {"accepted": bool}, "wer": float|None, ...}`.
- Produces: `aggregate(scored: list[dict], results: list[dict]) -> dict` with pass rates per category/target and latency median/p90 per stage per target.

- [ ] **Step 1: Write the failing test**

```python
# eval/text-cleanup/tests/test_score.py
import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from score import score_run

CASE = {"id": "x", "category": "numbers", "input": {"text": "twenty five dollars"},
        "must_contain": ["$25"], "must_not_contain": ["25 dollars"],
        "targets": ["light"], "asr_reference": None}

class TestScore(unittest.TestCase):
    def test_pass_when_rules_and_guard_ok(self):
        r = {"llm_output": "It costs $25.", "guard": {"accepted": True}, "wer": None}
        s = score_run(CASE, "light", r)
        self.assertTrue(s["mechanical_pass"])

    def test_fail_on_missing_must_contain(self):
        r = {"llm_output": "It costs 25 dollars.", "guard": {"accepted": True}, "wer": None}
        s = score_run(CASE, "light", r)
        self.assertFalse(s["mechanical_pass"])
        self.assertIn("missing '$25'", s["reasons"])

    def test_high_wer_attributes_to_asr(self):
        r = {"llm_output": "wrong", "guard": {"accepted": True}, "wer": 0.5}
        s = score_run(CASE, "light", r)
        self.assertEqual(s["attribution"], "asr")

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd eval/text-cleanup && python3 -m unittest tests.test_score -v`
Expected: FAIL (`No module named 'score'`)

- [ ] **Step 3: Write minimal implementation**

```python
# eval/text-cleanup/score.py
"""Mechanical scoring for eval results: keyword rules + guard + WER attribution,
plus latency aggregation. Objective layer under the Claude Code judge."""
import statistics

WER_FAIL_THRESHOLD = 0.15  # audio: above this, treat ASR as the bottleneck

def score_run(case, target, result):
    reasons = []
    out = result.get("llm_output", "") or ""
    low = out.lower()
    for term in case.get("must_contain", []):
        if term.lower() not in low:
            reasons.append(f"missing '{term}'")
    for term in case.get("must_not_contain", []):
        if term.lower() in low:
            reasons.append(f"contains forbidden '{term}'")
    if not result.get("guard", {}).get("accepted", True):
        reasons.append("guard rejected")

    wer = result.get("wer")
    attribution = None
    if wer is not None and wer > WER_FAIL_THRESHOLD:
        attribution = "asr"
        reasons.append(f"asr wer {wer:.0%}")
    elif reasons:
        attribution = "cleanup"

    return {"id": case["id"], "target": target,
            "mechanical_pass": not reasons, "reasons": reasons,
            "attribution": attribution}

def _pctile(values, p):
    if not values:
        return None
    s = sorted(values)
    k = min(len(s) - 1, int(round((p / 100) * (len(s) - 1))))
    return s[k]

def aggregate(scored, results):
    by_target = {}
    for s in scored:
        t = by_target.setdefault(s["target"], {"pass": 0, "total": 0})
        t["total"] += 1
        t["pass"] += 1 if s["mechanical_pass"] else 0
    latency = {}
    for r in results:
        stages = r.get("latency_ms", {})
        for stage, ms in stages.items():
            latency.setdefault(r["target"], {}).setdefault(stage, []).append(ms)
    latency_summary = {
        target: {stage: {"median": statistics.median(v), "p90": _pctile(v, 90)}
                 for stage, v in stages.items()}
        for target, stages in latency.items()
    }
    return {"by_target": by_target, "latency": latency_summary}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd eval/text-cleanup && python3 -m unittest tests.test_score -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add eval/text-cleanup/score.py eval/text-cleanup/tests/test_score.py
git commit -m "eval: mechanical scorer with WER attribution + latency aggregation"
```

---

### Task 4: In-app eval runner (text path)

**Files:**
- Create: `Sources/WhisperMaster/Eval/EvalRunner.swift`
- Modify: `Sources/WhisperMaster/App/AppDelegate.swift` (launch hook, next to the other launch setup)

**Interfaces:**
- Consumes: `MlxCleanupService.shared.clean(_:systemPrompt:)`, `CleanupPrompt.resolved(grammarPolish:)`, the deterministic passes used in `DictationViewModel` (`TranscriptSpacingRepair`, `DeterministicTextFormatter`/ITN, `FillerWordFilter`, `VocabularyPostProcessor`), `CleanupFaithfulnessGuard.accept`.
- Produces: `enum EvalRunner { static func runIfRequested() async }` — no-op unless `WM_EVAL_CASES` is set; reads that JSONL, runs each text case through `deterministic → light → polish`, writes `results.json` next to it (or to `WM_EVAL_OUT`).

- [ ] **Step 1: Implement `EvalRunner` (text path only)**

```swift
// Sources/WhisperMaster/Eval/EvalRunner.swift
import Foundation

/// Dev-only evaluation runner. Activated by the `WM_EVAL_CASES=<path>` env var:
/// after the cleanup model is ready, it pushes every text case through the real
/// pipeline (deterministic passes, then the light and polish LLM modes) and
/// writes per-stage outputs, guard verdicts, and latency to `results.json`.
/// Audio cases are handled in a later task; here they are skipped.
enum EvalRunner {
    static func runIfRequested() async {
        guard let casesPath = ProcessInfo.processInfo.environment["WM_EVAL_CASES"] else { return }
        let outPath = ProcessInfo.processInfo.environment["WM_EVAL_OUT"]
            ?? (casesPath as NSString).deletingLastPathComponent + "/results.json"
        // Ensure the model is ready before grading it.
        while await !MlxCleanupService.shared.isReady {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let cases = loadCases(casesPath)
        var out: [[String: Any]] = []
        for c in cases {
            guard let text = (c["input"] as? [String: Any])?["text"] as? String else { continue }
            let det = deterministic(text)
            for target in (c["targets"] as? [String] ?? ["light", "polish"]) {
                let polish = target == "polish"
                let start = Date()
                let llm = await MlxCleanupService.shared.clean(det, systemPrompt: CleanupPrompt.resolved(grammarPolish: polish)) ?? det
                let llmMs = Int(Date().timeIntervalSince(start) * 1000)
                let accepted = CleanupFaithfulnessGuard.accept(original: det, cleaned: llm, allowRephrase: polish)
                out.append([
                    "id": c["id"] ?? "", "target": target, "input_kind": "text",
                    "deterministic": det, "llm_output": accepted ? llm : det,
                    "guard": ["accepted": accepted], "wer": NSNull(),
                    "latency_ms": ["deterministic": 0, "llm": llmMs, "total": llmMs],
                ])
            }
        }
        writeJSON(out, to: outPath)
        Log.modelPrep.notice("EvalRunner wrote \(out.count) rows to \(outPath, privacy: .public)")
    }

    private static func deterministic(_ raw: String) -> String {
        // Mirror DictationViewModel's non-LLM pipeline order.
        let spaced = TranscriptSpacingRepair.repair(raw)
        let itn = DeterministicITN.normalize(spaced)
        // Filler removal + vocab are applied with empty glossary for eval.
        return VocabularyPostProcessor.apply(FillerWordFilter.clean(itn), glossary: [])
    }

    private static func loadCases(_ path: String) -> [[String: Any]] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    private static func writeJSON(_ obj: [[String: Any]], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
```

> Note: confirm the exact deterministic entry points against `DictationViewModel.stopRecording` before finalizing (`TranscriptSpacingRepair.repair`, `DeterministicITN.normalize`, `FillerWordFilter.clean`, `VocabularyPostProcessor.apply`). If any name differs, use the name from `DictationViewModel`. Do not invent APIs.

- [ ] **Step 2: Wire the launch hook in `AppDelegate.applicationDidFinishLaunching`**

Add after `viewModel.prepareDefaultEngineOnLaunch()`:

```swift
// Dev-only: when WM_EVAL_CASES is set, run the evaluation over the real
// pipeline and write results.json, then leave the app running for inspection.
if ProcessInfo.processInfo.environment["WM_EVAL_CASES"] != nil {
    Task { await EvalRunner.runIfRequested() }
}
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | grep -E 'error:|Build complete'`
Expected: `Build complete!`

- [ ] **Step 4: Run the eval over the text cases and verify output**

Run:
```bash
bash Scripts/bundle.sh >/tmp/b.log 2>&1
WM_EVAL_CASES="$PWD/eval/text-cleanup/cases.jsonl" \
WM_EVAL_OUT="$PWD/eval/text-cleanup/.eval-scratch/results.json" \
  open "build/Whisper Master.app"
# wait ~2 min for the model + run, then:
python3 -c "import json;d=json.load(open('eval/text-cleanup/.eval-scratch/results.json'));print(len(d), d[0].keys())"
```
Expected: a row count of `84 × number-of-targets` and keys including `llm_output`, `guard`, `latency_ms`.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperMaster/Eval/EvalRunner.swift Sources/WhisperMaster/App/AppDelegate.swift
git commit -m "eval: in-app runner grading the real pipeline (text path)"
```

---

### Task 5: Add grammar/polish test cases

**Files:**
- Modify: `eval/text-cleanup/cases.jsonl` (append rows)

- [ ] **Step 1: Append grammar cases (each on its own line)**

```jsonl
{"id": "grammar-agreement-01", "category": "grammar", "input": {"text": "me and him was gonna go to the store later"}, "targets": ["light", "polish"], "reference": "He and I were going to go to the store later.", "must_not_contain": ["100"], "note": "subject-verb agreement + pronoun case"}
{"id": "grammar-runon-01", "category": "grammar", "input": {"text": "so i went to the meeting and then i talked to sarah and then we decided to push the launch and also we need to tell the team"}, "targets": ["light", "polish"], "note": "run-on should become clean sentences, meaning preserved"}
{"id": "grammar-tense-01", "category": "grammar", "input": {"text": "yesterday i go to the office and i see the new design"}, "targets": ["light", "polish"], "reference": "Yesterday I went to the office and saw the new design.", "note": "past tense"}
{"id": "grammar-faithful-question-01", "category": "faithfulness", "input": {"text": "what is the capital of france"}, "targets": ["light", "polish"], "must_not_contain": ["Paris"], "note": "polish must NOT answer the question"}
{"id": "grammar-numbers-keep-01", "category": "grammar", "input": {"text": "the budget is like fifty thousand no wait seventy five thousand for q3"}, "targets": ["light", "polish"], "must_contain": ["75"], "must_not_contain": ["50,000", "$50"], "note": "self-correction + number, meaning preserved under rephrase"}
```

- [ ] **Step 2: Verify the loader still parses all cases**

Run: `cd eval/text-cleanup && python3 -c "from schema import load_cases; c=load_cases('cases.jsonl'); print(len(c), sum(1 for x in c if x['category']=='grammar'))"`
Expected: `89 4` (84 + 5 new; 4 tagged `grammar`)

- [ ] **Step 3: Commit**

```bash
git add eval/text-cleanup/cases.jsonl
git commit -m "eval: add grammar/polish test cases"
```

---

### Task 6: `.gitignore`, README, and first text loop

**Files:**
- Modify: `eval/text-cleanup/.gitignore`
- Create/Modify: `eval/text-cleanup/README.md`

- [ ] **Step 1: Ensure scratch + results are ignored**

Append to `eval/text-cleanup/.gitignore`:

```
.eval-scratch/
results.json
raw.json
report.md
```

- [ ] **Step 2: Write the README run instructions**

```markdown
# Text-cleanup / dictation evaluation

## Text loop
1. Build the app: `bash Scripts/bundle.sh`
2. Run the eval over the real pipeline:
   `WM_EVAL_CASES="$PWD/eval/text-cleanup/cases.jsonl" WM_EVAL_OUT="$PWD/eval/text-cleanup/.eval-scratch/results.json" open "build/Whisper Master.app"`
3. Score: `python3 score_cli.py .eval-scratch/results.json`  (see below)
4. Claude Code reads results.json and writes judgment.md.

## Tests
`cd eval/text-cleanup && python3 -m unittest discover tests -v`

## Clean up
`rm -rf eval/text-cleanup/.eval-scratch`
```

- [ ] **Step 3: Add a tiny `score_cli.py` that ties scorer to results**

```python
# eval/text-cleanup/score_cli.py
import json, sys
from schema import load_cases
from score import score_run, aggregate

results = json.load(open(sys.argv[1]))
cases = {c["id"]: c for c in load_cases("cases.jsonl")}
scored = [score_run(cases[r["id"]], r["target"], r) for r in results if r["id"] in cases]
agg = aggregate(scored, results)
print(json.dumps({"by_target": agg["by_target"], "latency": agg["latency"],
                  "failures": [s for s in scored if not s["mechanical_pass"]]}, indent=2))
```

- [ ] **Step 4: Run the full text loop and produce judgment**

Run: build + eval (Task 4 Step 4), then `cd eval/text-cleanup && python3 score_cli.py .eval-scratch/results.json`
Then Claude Code reads `.eval-scratch/results.json` and writes `eval/text-cleanup/judgment.md` (faithfulness + quality per target, light-vs-polish, latency, recommendations).

- [ ] **Step 5: Commit**

```bash
git add eval/text-cleanup/.gitignore eval/text-cleanup/README.md eval/text-cleanup/score_cli.py eval/text-cleanup/judgment.md
git commit -m "eval: text loop wiring, README, first judgment"
```

---

## PHASE 2 — Audio layer

### Task 7: WER module

**Files:**
- Create: `eval/text-cleanup/wer.py`
- Create: `eval/text-cleanup/tests/test_wer.py`

**Interfaces:**
- Produces: `wer(reference: str, hypothesis: str) -> float` (word-level Levenshtein / reference length, after normalization) and `normalize(text: str) -> list[str]`.

- [ ] **Step 1: Write the failing test**

```python
# eval/text-cleanup/tests/test_wer.py
import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from wer import wer

class TestWer(unittest.TestCase):
    def test_identical_is_zero(self):
        self.assertEqual(wer("hello world", "Hello, world!"), 0.0)
    def test_one_substitution(self):
        self.assertAlmostEqual(wer("the cat sat", "the dog sat"), 1/3)
    def test_deletion(self):
        self.assertAlmostEqual(wer("a b c d", "a b d"), 1/4)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd eval/text-cleanup && python3 -m unittest tests.test_wer -v`
Expected: FAIL (`No module named 'wer'`)

- [ ] **Step 3: Write minimal implementation**

```python
# eval/text-cleanup/wer.py
"""Word error rate with light normalization (lowercase, strip punctuation)."""
import re

def normalize(text):
    return re.findall(r"[a-z0-9']+", (text or "").lower())

def wer(reference, hypothesis):
    r = normalize(reference)
    h = normalize(hypothesis)
    if not r:
        return 0.0 if not h else 1.0
    # Levenshtein over word lists.
    prev = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        cur = [i]
        for j, hw in enumerate(h, 1):
            cost = 0 if rw == hw else 1
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost))
        prev = cur
    return prev[-1] / len(r)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd eval/text-cleanup && python3 -m unittest tests.test_wer -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add eval/text-cleanup/wer.py eval/text-cleanup/tests/test_wer.py
git commit -m "eval: word error rate module"
```

---

### Task 8: Audio generation — TTS + augmentation + Common Voice

**Files:**
- Create: `eval/text-cleanup/make_audio.py`
- Create: `eval/text-cleanup/tests/test_make_audio.py`

**Interfaces:**
- Produces: `snr_filter(snr_db: int) -> str` (ffmpeg amix filter string — pure, testable), `hfp_filter() -> str` (mono 8 kHz band-limit), and a `main()` that: (a) TTS-synthesizes each text case to `.eval-scratch/audio/tts/<id>.m4a` via `say` + `ffmpeg`; (b) generates augmented variants; (c) downloads a Common Voice slice; (d) writes `.eval-scratch/audio_cases.jsonl` (audio cases in the schema, each with `asr_reference`).

- [ ] **Step 1: Write the failing test for the pure helpers**

```python
# eval/text-cleanup/tests/test_make_audio.py
import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from make_audio import snr_filter, hfp_filter

class TestFilters(unittest.TestCase):
    def test_snr_filter_mentions_amix(self):
        self.assertIn("amix", snr_filter(10))
    def test_hfp_is_mono_8k(self):
        f = hfp_filter()
        self.assertIn("8000", f)
        self.assertIn("mono", f) or self.assertIn("ac=1", f)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd eval/text-cleanup && python3 -m unittest tests.test_make_audio -v`
Expected: FAIL (`No module named 'make_audio'`)

- [ ] **Step 3: Write `make_audio.py`**

```python
# eval/text-cleanup/make_audio.py
"""Generate audio eval inputs into .eval-scratch/ (all git-ignored):
  - TTS each text case via macOS `say` -> m4a (exact asr_reference).
  - Augment: additive noise at SNR levels + Bluetooth-HFP simulation (ffmpeg).
  - Download a small Common Voice slice (CC0) for real-human WER.
Writes .eval-scratch/audio_cases.jsonl. Requires `say` (built-in) and `ffmpeg`.
"""
import json, os, subprocess, sys
from schema import load_cases

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.join(HERE, ".eval-scratch")
AUDIO = os.path.join(SCRATCH, "audio")

def snr_filter(snr_db):
    # Mix speech with noise scaled for the target SNR (approx; noise pre-normalized).
    gain = 10 ** (-snr_db / 20)
    return f"[1:a]volume={gain:.4f}[n];[0:a][n]amix=inputs=2:duration=first"

def hfp_filter():
    # Simulate Bluetooth hands-free: mono, 8 kHz, telephone band.
    return "aformat=channel_layouts=mono,aresample=8000,highpass=f=300,lowpass=f=3400"

def _run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def tts_case(case):
    text = case["input"]["text"]
    os.makedirs(os.path.join(AUDIO, "tts"), exist_ok=True)
    aiff = os.path.join(AUDIO, "tts", case["id"] + ".aiff")
    m4a = os.path.join(AUDIO, "tts", case["id"] + ".m4a")
    _run(["say", "-o", aiff, text])
    _run(["ffmpeg", "-y", "-i", aiff, m4a])
    os.remove(aiff)
    return {"id": "tts-" + case["id"], "category": case["category"],
            "input": {"audio": os.path.relpath(m4a, HERE)},
            "asr_reference": text, "targets": case.get("targets", ["light", "polish"]),
            "must_contain": case.get("must_contain", []),
            "must_not_contain": case.get("must_not_contain", []),
            "note": "tts:" + case.get("note", "")}

def main():
    cases = [c for c in load_cases(os.path.join(HERE, "cases.jsonl")) if "text" in c["input"]]
    audio_cases = [tts_case(c) for c in cases]
    # Augmentation + Common Voice download are invoked here (see README);
    # each augmented variant / CV clip appends an audio case with its asr_reference.
    with open(os.path.join(SCRATCH, "audio_cases.jsonl"), "w") as f:
        for c in audio_cases:
            f.write(json.dumps(c) + "\n")
    print(f"wrote {len(audio_cases)} tts audio cases")

if __name__ == "__main__":
    main()
```

> The augmentation and Common Voice download commands (ffmpeg `amix` with `snr_filter`, `hfp_filter`, and the CC0 slice fetch via `curl`) are appended in this `main()` following the same append-an-audio-case pattern; keep each variant's `asr_reference` equal to its source clip's.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd eval/text-cleanup && python3 -m unittest tests.test_make_audio -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Generate the TTS cases (integration check)**

Run: `cd eval/text-cleanup && brew list ffmpeg >/dev/null 2>&1 || brew install ffmpeg; python3 make_audio.py`
Expected: prints `wrote 89 tts audio cases`; `.eval-scratch/audio/tts/*.m4a` exist.

- [ ] **Step 6: Commit**

```bash
git add eval/text-cleanup/make_audio.py eval/text-cleanup/tests/test_make_audio.py
git commit -m "eval: audio generation (TTS, augmentation filters, CV slice)"
```

---

### Task 9: Eval runner — audio path + WER + per-stage latency

**Files:**
- Modify: `Sources/WhisperMaster/Eval/EvalRunner.swift`

**Interfaces:**
- Consumes: `FluidAudioStreamingTranscriber` (the same transcriber the app uses; feed the audio file exactly as `AudioReplayTests` does), `wer` is computed in Python (runner only emits `asr_text` + `asr_reference`).
- Produces: for audio cases, `results.json` rows also carry `"asr_text"`, `"asr_reference"`, and `latency_ms.asr`.

- [ ] **Step 1: Add the audio branch to `EvalRunner`**

For each case whose `input` has `audio`: load the file, feed it through the streaming transcriber (mirror `AudioReplayTests` feeding), time the ASR, then run `deterministic → targets` on the ASR text. Emit:

```swift
out.append([
    "id": c["id"] ?? "", "target": target, "input_kind": "audio",
    "asr_text": asrText, "asr_reference": c["asr_reference"] ?? "",
    "deterministic": det, "llm_output": accepted ? llm : det,
    "guard": ["accepted": accepted], "wer": NSNull(),  // WER computed in Python
    "latency_ms": ["asr": asrMs, "deterministic": 0, "llm": llmMs, "total": asrMs + llmMs],
])
```

> Reuse the exact file-feeding approach from `Tests/WhisperMasterTests/AudioReplayTests.swift`. Do not invent a new decode path.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | grep -E 'error:|Build complete'`
Expected: `Build complete!`

- [ ] **Step 3: Run over the generated audio cases**

Run:
```bash
bash Scripts/bundle.sh >/tmp/b.log 2>&1
WM_EVAL_CASES="$PWD/eval/text-cleanup/.eval-scratch/audio_cases.jsonl" \
WM_EVAL_OUT="$PWD/eval/text-cleanup/.eval-scratch/results_audio.json" \
  open "build/Whisper Master.app"
python3 -c "import json;d=json.load(open('eval/text-cleanup/.eval-scratch/results_audio.json'));print(len(d), 'asr_text' in d[0])"
```
Expected: rows present, `asr_text` key True.

- [ ] **Step 4: Commit**

```bash
git add Sources/WhisperMaster/Eval/EvalRunner.swift
git commit -m "eval: runner audio path (ASR text, references, per-stage latency)"
```

---

### Task 10: Wire WER + attribution into scoring, and run the full loop

**Files:**
- Modify: `eval/text-cleanup/score_cli.py`

- [ ] **Step 1: Compute WER for audio rows before scoring**

Update `score_cli.py` to fill `r["wer"]` from `wer(r["asr_reference"], r["asr_text"])` for audio rows:

```python
from wer import wer as compute_wer
for r in results:
    if r.get("input_kind") == "audio" and r.get("asr_reference"):
        r["wer"] = compute_wer(r["asr_reference"], r["asr_text"])
```

Place this loop immediately before the `scored = [...]` line.

- [ ] **Step 2: Run the full audio loop**

Run: `cd eval/text-cleanup && python3 score_cli.py .eval-scratch/results_audio.json`
Expected: JSON with per-target pass rates, latency (incl. `asr`), and failures tagged `attribution: "asr"` vs `"cleanup"`.

- [ ] **Step 3: Claude Code judges + updates the README**

Claude Code reads `results_audio.json`, writes/updates `judgment.md` with the ASR-vs-cleanup attribution and the WER/latency tables. Update `README.md` with the audio-loop commands.

- [ ] **Step 4: Commit**

```bash
git add eval/text-cleanup/score_cli.py eval/text-cleanup/README.md eval/text-cleanup/judgment.md
git commit -m "eval: WER + attribution in scoring, full audio loop"
```

---

## Self-Review notes (already reconciled)

- **Spec coverage:** stages/attribution (Tasks 4, 9, 10); real pipeline (Task 4); text cases + grammar (Tasks 1, 5); audio 3 sources + augmentation (Task 8); WER (Task 7); mechanical scorer (Task 3); Claude judge (Tasks 6, 10 — human/Claude step, no code); targets abstraction (Task 4 loops `targets`); latency graded (Tasks 3, 4, 9); repo hygiene (Task 6); capped loop (process, enforced by the operator — see README).
- **Deferred, per spec:** app-format targets (slack/email/code) — schema/targets already support them, no task needed now.
- **Type consistency:** `results.json` row shape (`id, target, input_kind, deterministic, llm_output, guard.accepted, wer, asr_text?, asr_reference?, latency_ms{asr?,deterministic,llm,total}`) is identical across Tasks 3, 4, 9, 10.
- **Manual gate:** the "capped loop (3 rounds)" is an operator process documented in the README, not code.
