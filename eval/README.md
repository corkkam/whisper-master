# Evaluation — how it works and how to check it

This is the quality eval for Whisper Master’s dictation pipeline. It grades the
**real shipped code** (Parakeet ASR + deterministic cleanup + on-device qwen),
not a proxy model and not Ollama.

Design spec: `docs/superpowers/specs/2026-07-06-eval-engine-design.md`.
Agent notes: `.claude/skills/eval-pipeline/SKILL.md`.

---

## What it answers

1. Did the mic hear the words? (WER on audio cases)
2. Did deterministic cleanup + the LLM make the text *better* without inventing,
   answering, or dropping content?
3. Did a destination-specific format (Slack / email / code) do the right shape
   of rewrite?
4. How long did each stage take?

A failure is attributed to **ASR** or **cleanup**, so a noisy clip is not blamed
on the prompt.

---

## Pipeline

```
cases.jsonl
    │
    ▼
built app, launched via `open`          ← never exec the Mach-O directly
    │  env: WM_EVAL_CASES, WM_EVAL_OUT
    ▼
AppDelegate → EvalRunner.runIfRequested()
    │
    ├─ text case  → deterministic passes → LLM per target → faithfulness guard
    └─ audio case → FluidAudioStreamingTranscriber (same chunking as the live
                    mic) → then the same deterministic + LLM path
    │
    ▼
results.json          (per case × target: outputs, guard, latency)
    │
    ├─ swift run eval-score <results.json> <cases.jsonl>
    │       objective: must_contain / must_not_contain + WER
    │
    ├─ Claude reads results.json → judgment.md   (subjective quality)
    │
    └─ push-run → eval dashboard                 (history over time)
```

**Grade the real pipeline, never a stand-in.** `EvalRunner` calls
`TranscriptSpacingRepair` → `SelfCorrectionCollapser` → `DeterministicITN` →
`FillerWordFilter` → `VocabularyPostProcessor`, then `MlxCleanupService` with
the **real** `CleanupFaithfulnessGuard`. The scorer does not re-run the model.

---

## Pieces and where they live

| Piece | Path | Role |
|---|---|---|
| In-app runner | `Sources/WhisperMaster/Eval/EvalRunner.swift` | Fired from `AppDelegate` when `WM_EVAL_CASES` is set. Writes `results.json`. |
| Targets | `Sources/WhisperMaster/Transcription/CleanupTarget.swift` | `light`, `polish` (shipped) + `slack`, `email`, `code` (eval-only). |
| Prompts | `CleanupPrompt.swift` **and** `eval/text-cleanup/prompt*.txt` | Must stay verbatim. Change both, then re-run. |
| Guard | `CleanupFaithfulnessGuard.swift` | Rejects invented / answering / coding output. Diagnostic, not a pass/fail. |
| Case schema + WER + scorer | `eval/text-cleanup/EvalScore/` | Pure SwiftPM lib `EvalScoreKit`. No app / MLX deps. |
| CLI | `eval/text-cleanup/EvalScoreCLI/` | `swift run eval-score <results.json> <cases.jsonl>` |
| Baseline cases | `eval/text-cleanup/cases.jsonl` | ~89 text cases, default targets `light`+`polish`. |
| Destination cases | `eval/text-cleanup/flow-cases.jsonl` | Slack / email / code suite. |
| One-shot driver | `eval/text-cleanup/run-eval.sh` | Quit app → `launchctl setenv` → `open` → wait → optional push. |
| Audio glue | `make_audio.sh`, `fetch_librispeech.sh` | TTS + HFP/noise aug + LibriSpeech slice → `.eval-scratch/` (git-ignored). |
| Dashboard | `eval/dashboard/` | SvelteKit. Public reads, token-gated ingest. Scoring is a TS port of `EvalScoreKit`. |
| Historical Ollama harness | `run.py`, `guard.py` | Left as history. Do not extend. Do not use for ship decisions. |

`AudioReplayTests` is a **separate** regression bench (committed `paragraph-N.m4a`
fixtures through the live streaming path). It is not the eval engine, but it is
the other gate before shipping a transcription change:

```bash
swift test --filter AudioReplayTests
```

---

## Targets

A target is `{ id, prompt, allowRephrase }`. The runner groups work **by
target** so the LLM’s system-prompt KV cache stays primed.

| id | Ships? | Rephrase? | Prompt |
|---|---|---|---|
| `light` | Settings → Smart cleanup | no | `CleanupPrompt.system` / `prompt.txt` |
| `polish` | Settings → Polish my English (off by default) | yes | `CleanupPrompt.grammarPolish` |
| `slack` | **eval only** | yes | `CleanupPrompt.slack` / `prompt-slack.txt` |
| `email` | **eval only** | yes | `CleanupPrompt.email` / `prompt-email.txt` |
| `code` | **eval only** | yes | `CleanupPrompt.code` / `prompt-code.txt` |

`slack` / `email` / `code` must **not** be called from `DictationViewModel`.
Adding a destination is: a case on `CleanupTarget` + a prompt (Swift **and**
`.txt`) + cases that list it. The runner and scorer take the id as a string.

---

## Case schema

One JSON object per line.

```jsonc
{
  "id": "flow-slack-casual",
  "category": "slack",                    // numbers | faithfulness | disfluency | grammar | slack | email | code | …
  "input": { "text": "um hey can you…" }  // or { "audio": "/abs/or/rel/path.m4a" }
                                          // legacy: a bare string is treated as text
  "targets": ["slack"],                   // default ["light","polish"]
  "reference": "Hey, can you…",           // optional ideal final (for the judge)
  "asr_reference": "um hey can you…",     // required for audio — exact spoken words → WER
  "must_contain": ["PR"],
  "must_not_contain": ["Best,", "Dear"],
  "note": "casual Slack, no email chrome"
}
```

Rules:

- Audio cases **must** have `asr_reference`.
- `must_contain` / `must_not_contain` are case-insensitive substring checks on
  the **final** `llm_output` (or the deterministic fallback if the guard rejected).
- The guard verdict is **not** a pass/fail. A rejection means the safe
  deterministic text was kept — for a faithfulness case that is often the
  correct result. An unfaithful *acceptance* is still caught by `must_not_contain`.

---

## How to run

Need: Apple Silicon, a built app with the cleanup model already downloaded
(or the first run will wait while it loads), and for audio cases `ffmpeg` if
you want augmentation.

### 1. Build the app you will grade

```bash
bash Scripts/bundle.sh          # → build/Whisper Master.app
# or install it:
bash Scripts/install.sh         # → /Applications/Whisper Master.app  (run-eval.sh default)
```

The runner lives **inside the app**. Scoring the last Release you shipped is
the point — don’t grade a stale binary after changing a prompt.

### 2. One-shot (recommended)

```bash
# light + polish baseline
bash eval/text-cleanup/run-eval.sh eval/text-cleanup/cases.jsonl "light+polish"

# Slack / email / code destinations
bash eval/text-cleanup/run-eval.sh eval/text-cleanup/flow-cases.jsonl "flow destinations"
```

What that script does:

1. Quits any running Whisper Master.
2. Sets `WM_EVAL_CASES` / `WM_EVAL_OUT` via `launchctl setenv` (LaunchServices
   does not inherit your shell env).
3. `open`s the app. **Do not exec the bundle’s Mach-O** — TCC can’t find the
   Info.plist usage strings and the mesh CoreBluetooth scan hard-crashes.
4. Waits until `results.json` appears and its size holds steady (default 20 min).
5. Pushes to the dashboard unless `NO_PUSH=1`.

Useful env:

| var | default | meaning |
|---|---|---|
| `APP` | `/Applications/Whisper Master.app` | Which bundle to launch |
| `OUT` | `eval/text-cleanup/.eval-scratch/results.json` | Where `results.json` lands |
| `DASHBOARD_URL` | `http://localhost:5173` | Ingest target |
| `TIMEOUT` | `1200` | Seconds to wait for the write |
| `NO_PUSH=1` | off | Skip the dashboard |

```bash
# grade the just-built bundle, keep results local
APP="build/Whisper Master.app" NO_PUSH=1 \
  bash eval/text-cleanup/run-eval.sh eval/text-cleanup/cases.jsonl "local"
```

### 3. Score without re-running the model

```bash
swift run eval-score \
  eval/text-cleanup/.eval-scratch/results.json \
  eval/text-cleanup/cases.jsonl
```

Prints `total / pass / fail`, per-target pass rate + median/p90 latency, and
every failing id with reasons and `asr` vs `cleanup` attribution. Tweak a
`must_contain` and re-run this — you do not need the LLM again.

### 4. Subjective judge

Read `results.json` (and the scorer output) and write
`eval/text-cleanup/judgment.md`: faithfulness, quality, light-vs-polish (or
destination shape), latency, what to change. Keyword rules cannot make that
call. Cap the improve loop at **3 rounds**.

### 5. Audio cases (optional)

```bash
cd eval/text-cleanup
bash make_audio.sh cases.jsonl          # TTS every text case → .eval-scratch/audio/
# optional: bash fetch_librispeech.sh   # real-human WER anchor
NO_PUSH=1 bash run-eval.sh .eval-scratch/audio_cases.jsonl "audio"
swift run eval-score .eval-scratch/results.json .eval-scratch/audio_cases.jsonl
```

TTS is optimistic (clean synthetic speech). LibriSpeech is the real-accuracy
number. HFP + pink-noise variants are the degradation curve.

---

## How to check it actually ran

After `run-eval.sh` (or a manual `open`):

1. **`results.json` exists** at `OUT` (default
   `eval/text-cleanup/.eval-scratch/results.json`). The script already fails if
   it never appears.
2. **Row count matches `cases × listed targets`.** A destination file that only
   lists `slack` should not grow light/polish rows.
   ```bash
   python3 -c "import json; r=json.load(open('eval/text-cleanup/.eval-scratch/results.json'));
   print(len(r), 'rows');
   from collections import Counter; print(Counter(x['target'] for x in r))"
   ```
3. **Each row has** `id`, `target`, `input_kind`, `deterministic`, `llm_output`,
   `guard.accepted`, `latency_ms`. Audio rows also have `asr_text` /
   `asr_reference`.
4. **`eval-score` exits 0** and the printed fail list is the thing you act on.
5. **Unit tests** (no models, no audio, no app launch):
   ```bash
   swift test --filter EvalScoreKitTests
   swift test --filter CleanupTargetTests
   ```
   `EvalScoreKitTests` locks the schema, WER, and “guard is diagnostic” rule.
   `CleanupTargetTests` locks that `light`/`polish` still map to the shipped
   prompts and that destination prompts are distinct.
6. **Dashboard** (if you pushed): open the new run, confirm the target tiles
   match `eval-score`, and that Slack/email/code lines show on destination runs.

If the app launches and nothing is written: the cleanup model did not become
ready (`EvalRunner` logs `cleanup model not ready; aborting` under
`app.whispermaster.mac` / `Log.modelPrep`). Open Settings → Voice engine once
so the qwen archive is installed, then re-run.

If you see a CoreBluetooth crash at launch: you exec’d the binary. Use `open`.

---

## Dashboard

Public history: [whisper-eval-dashboard.vercel.app](https://whisper-eval-dashboard.vercel.app)
(auto-deploys from `dev` when `eval/dashboard/` changes).

Local:

```bash
cd eval/dashboard
cp .env.example .env          # DATABASE_URL (must include /dbname in the path) + INGEST_TOKEN
npm install
npm run db:push
npm run dev                   # http://localhost:5173
```

Reads are public. `POST /api/ingest` needs `x-ingest-token`. `push-run.mjs`
sends it. Re-push a finished run:

```bash
cd eval/dashboard
npm run push-run -- ../text-cleanup/.eval-scratch/results.json \
  ../text-cleanup/cases.jsonl "light+polish"
```

`src/lib/scoring.ts` is a port of `EvalScoreKit` — keep them in sync if you
change a scoring rule.

---

## Adding a case

1. Append a line to `cases.jsonl` (baseline) or `flow-cases.jsonl` (destination).
2. Give it a unique `id`. List only the targets that should run.
3. Write `must_contain` / `must_not_contain` against the **final** text, not
   the raw ASR. For faithfulness, the forbidden strings are the answers the
   model must not invent (`Paris`, `def `, `180`, …).
4. Re-run that file. Confirm the new id appears in `results.json` and in the
   `eval-score` fail list if you expect it to fail.

Do not put destination-only cases in `cases.jsonl` — that file is the
light+polish baseline and its pass rate is compared across runs.

---

## Adding a target

1. Add a case to `CleanupTarget` and a prompt on `CleanupPrompt`.
2. Copy the prompt into `eval/text-cleanup/prompt-<id>.txt`.
3. Author cases that list the new id.
4. `swift test --filter CleanupTargetTests` (extend it).
5. Dashboard cards already render unknown target ids; add a label in
   `CaseCard.svelte` / `OutcomeTiles.svelte` if you want a pretty name.

Do not wire a new target into the paste path unless that is an explicit
product change.

---

## What “good” looks like (last recorded findings)

From `eval/text-cleanup/judgment.md` (re-check after any prompt/guard change):

- Clean LibriSpeech speech: ~**3.4%** mean WER.
- Bottleneck is **noise (~23%)** and **Bluetooth-HFP (~16%)**, not clean hearing.
- `polish` must not answer questions. The guard’s anti-answer rule is load-bearing;
  `polish` stays experimental / off by default regardless.

---

## Related but not this engine

| Thing | What it is |
|---|---|
| `swift test` | Pure unit tests. Always green on a fresh clone. |
| `swift test --filter AudioReplayTests` | Replay committed recordings through the live streaming path. Skips if no fixtures. |
| Insights tab | Live usage (WPM, streak, apps). Not an eval. |
| `run.py` | Old Ollama model bake-off. Historical. |
