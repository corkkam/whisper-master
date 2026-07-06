# Dictation evaluation engine — design

## Purpose

We ship a multi-stage dictation pipeline but we cannot currently answer "is it
actually good?" with anything better than a keyword pass/fail that runs against
Ollama, not the real model. This spec defines a **quality-first evaluation
engine** that:

1. Runs test cases through the **real shipped pipeline** (Parakeet ASR +
   deterministic passes + the MLX cleanup model), not a proxy.
2. Grades each stage and **attributes failures** to the stage that caused them
   (bad hearing vs bad cleanup).
3. Combines **mechanical scoring** (objective rules) with a **Claude Code judge**
   (subjective "does this read well / is it faithful") — the piece keyword rules
   can never do.
4. Measures **latency per stage**, because latency is a first-class product
   concern here.
5. Is **extensible**: adding app-specific formatting later (Slack/email/code, à
   la Wispr Flow) is "add a target," not "rewrite the engine."

Non-goals: an automated Claude-API judge (Claude Code is the judge), any UI, a
new scoring DSL.

## The core idea: evaluate stages, not one blob

The real pipeline is a chain:

```
audio → [Parakeet ASR] → text → [deterministic passes] → [LLM cleanup/format] → final
```

The engine can **inject a case at any stage** and **grade any stage**:

- **Text cases** inject at the text stage (skip ASR) — grade cleanup/formatting.
- **Audio cases** inject at the top — grade ASR (WER vs a reference) *and*
  cleanup *and* the final output, so a failure is attributed: "ASR misheard
  (WER 18%)" vs "ASR was fine, cleanup dropped it."

## Components

### 1. Case schema (`eval/text-cleanup/cases.jsonl`, generalized)

```jsonc
{
  "id": "grammar-tense-01",
  "category": "grammar",              // numbers|faithfulness|disfluency|grammar|realistic|…
  "input": { "text": "me and him was gonna go" },   // OR { "audio": "fixtures/audio/paragraph-1.m4a" }
  "reference": "He and I were going to go.",         // optional ideal final output (anchors the judge)
  "asr_reference": "me and him was gonna go",         // required for audio cases (exact words) → WER
  "targets": ["light", "polish"],     // which cleanup/format modes to run this case through
  "must_contain": ["going"],           // optional mechanical rule
  "must_not_contain": ["100"],
  "note": "subject-verb agreement + pronoun case"
}
```

`targets` is the extensibility hinge: today `["light","polish"]`; tomorrow
`["slack","email","code"]`. The existing 84 cases migrate by wrapping `input`
as `{ "text": … }` and defaulting `targets` to `["light","polish"]`.

### 2. Test cases and audio data (all sources, one pass)

- **Text cases:** the existing 84 + new `grammar`/`polish` cases (run-ons, tense
  and agreement errors, rambly realistic speech) where the correct answer is a
  clean rewrite, not just filler removal.
- **Audio cases from three sources at once:**
  1. **TTS-synthesized** from the text cases via macOS `say` (offline, unlimited,
     exact `asr_reference`). Covers our exact patterns end-to-end. *Caveat,
     documented in the report: synthetic speech is cleaner than real speech, so
     its WER is optimistic — used for controlled coverage/regression, not for
     the true-accuracy number.*
  2. **Mozilla Common Voice** slice (CC0) — real human, varied accents/mics; the
     real-accuracy anchor. A small fixed slice (~50 clips) to stay bounded,
     downloaded on demand (see repo hygiene).
  3. The **7 existing committed recordings** (`Fixtures/audio/paragraph-N.m4a` +
     `paragraphs.md`).
- **Augmentation** applied to any clip: additive background noise at set SNR
  levels and a **Bluetooth-HFP simulation** (downsample to mono ~8 kHz, band-
  limit), producing a **degradation curve** (WER vs condition). This is how we
  test "noise around me / bad mic" repeatably.

### 3. In-app eval runner (Swift, dev-only)

Triggered by an env var (`WM_EVAL_CASES=<path>`). After the model is ready it
runs every `case × target` through the real pipeline from the case's injection
point and emits, per run:

```jsonc
{
  "id": "...", "target": "polish",
  "input_kind": "audio",
  "asr_text": "...", "wer": 0.12,        // audio only
  "deterministic": "...",
  "llm_output": "...",
  "guard": { "accepted": true },
  "latency_ms": { "asr": 320, "deterministic": 4, "llm": 480, "total": 804 }
}
```

Written to `eval/text-cleanup/results.json` (git-ignored). Driving it is a loop I
run: set the env var, `open` the app, wait for the file, read it.

### 4. Mechanical scorer (Python, reuses `guard.py`)

Objective pass/fail per `case × target`: `must_contain`/`must_not_contain`, guard
accept/reject (strict for `light`, `allowRephrase` for `polish`), WER threshold
for audio, and length sanity. Produces the **attribution**: if `wer` is high the
failure is tagged ASR; if ASR is clean but the final is wrong it's tagged
cleanup.

### 5. Claude Code judge (me)

I read `results.json` and score each output on a small **per-target rubric**:

- **Faithfulness** (critical — any violation fails): preserved meaning and facts,
  resolved self-corrections, did not invent/answer/translate/compute.
- **Quality**: reads as clear, natural English; for `polish`, did it actually
  improve grammar over `light` (or did it over-reach / change meaning).
- **Verdict vs deterministic:** better / same / worse.

Output: `eval/text-cleanup/judgment.md` — per-category and per-target pass rates,
the failing cases with reasons, the latency table (median/p90 per stage, and the
**light-vs-polish delta**), and concrete recommendations (prompt tweak, guard
tweak, model concern).

### 6. Targets abstraction

A target = `{ id, systemPrompt, guardMode, judgeRubricNotes }` — an LLM
cleanup/format mode. The runner always captures the ASR and deterministic stage
outputs (for attribution), then runs each listed target's prompt on the
deterministic text. The engine is `cases × targets → outputs → score`. Adding
Slack/email/code later is: register a target + add cases that list it + a rubric
note. No runner or scorer change.

### 7. Improve loop, capped

Run → judge → identify failures → tweak prompt/guard → re-run → compare. **Hard
cap: stop after 3 rounds, or earlier when a round yields no net improvement.**

## Latency as a graded metric

Per-stage timing (`asr`, `deterministic`, `llm`, `total`) recorded for every run.
The report shows median/p90 per stage per target and the polish-over-light delta,
so the quality gain of polish is always weighed against its added latency.

## Repo hygiene & tooling

- **Generated/downloaded audio is git-ignored scratch**, produced on demand:
  TTS output, augmented variants, the Common Voice slice, and `results.json` all
  live under a git-ignored dir (same discipline as the model mirror). Only the
  tiny existing committed fixtures stay in git.
- **New tooling** (documented, Homebrew/`say`/curl): `say` (built-in) for TTS;
  `ffmpeg` (or `sox`) for format conversion + noise/HFP augmentation; `curl` for
  the Common Voice slice.

## File layout

```
eval/text-cleanup/
  cases.jsonl          # generalized cases (committed)
  prompt.txt           # light prompt (committed, == CleanupPrompt.system)
  prompt-polish.txt    # polish prompt (committed, == CleanupPrompt.grammarPolish)
  guard.py             # mechanical guard (committed)
  score.py             # mechanical scorer + attribution + latency aggregation (committed)
  make_audio.py        # TTS + Common Voice fetch + augmentation → .eval-scratch/ (committed)
  README.md            # how to run the whole loop (committed)
  .eval-scratch/       # git-ignored: generated audio, Common Voice, results.json
  judgment.md          # my judgment output (committed as the latest run's record)
Sources/WhisperMaster/… (or a dev-only file)
  EvalRunner.swift     # WM_EVAL_CASES runner over the real pipeline
```

## What's built now vs structured-for-later

- **Built now:** generalized schema; text + audio runner (all three audio
  sources + augmentation); mechanical scorer with attribution; latency metrics;
  me as judge with the rubric; `light` + `polish` targets; the capped loop.
- **Structured for later (no redesign needed):** app-format targets
  (slack/email/code) — the schema and target abstraction already support them.

## Verification

1. `make_audio.py` produces TTS + augmented + Common Voice clips into scratch.
2. `WM_EVAL_CASES=… open` the app → `results.json` appears with per-stage
   outputs, WER, and latency for every `case × target`.
3. `score.py` prints objective pass rates + attribution; unit-tested where pure.
4. I read `results.json`, write `judgment.md`, and we run one improve-loop round
   end to end to confirm the cycle works.
