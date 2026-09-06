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
4. How long did each stage take, **per word**?
5. And — because a keyword rule only sees what somebody thought to assert —
   **what shape is the output**: how much of the input survived, how much the
   model changed, and whether it put words there that were never said. See
   **Continuous metrics** below.

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
    └─ push-run → whisper.corkkam.com/eval       (history over time)
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
| Baseline cases | `eval/text-cleanup/cases.jsonl` | 116 text cases across 16 categories, default targets `light`+`polish`. |
| Destination cases | `eval/text-cleanup/flow-cases.jsonl` | Slack / email / code suite. |

**Adding a batch of cases: stage them in a separate file first.** Write them to
e.g. `cases-extended.jsonl`, run *that* file, fix every assertion that failed for
the case's own fault rather than the pipeline's, then merge and delete it. Of the
24 cases added on 2026-08-23, three had wrong assertions — one forbade a
one-character term, one asserted a rewrite a rephrasing target is allowed to
make, and one was too weak to catch the bug it had found. Merging first would have
turned the suite red for the suite's own reasons.
| One-shot driver | `eval/text-cleanup/run-eval.sh` | Quit app → `launchctl setenv` → `open` → wait → optional push. |
| Audio glue | `make_audio.sh`, `fetch_librispeech.sh` | TTS + HFP/noise aug + LibriSpeech slice → `.eval-scratch/` (git-ignored). |
| Pusher | `eval/text-cleanup/push-run.mjs` | `POST /api/eval/ingest`. Needs `EVAL_INGEST_TOKEN`. |
| History page | landing repo, `app/eval/` + `lib/eval/` | Public reads, token-gated ingest. `lib/eval/scoring.ts` is a TS port of `EvalScoreKit`. |
| Assistant suite | `eval/text-cleanup/assistant-cases.jsonl` + `App/AgentToolEval.swift` | Shown the tools, does the model call the right one? Two targets: the shipped prompt and native tool calling. |
| Transcription suite | `eval/text-cleanup/make-transcription-cases.mjs` | The speech model on its own, graded on word error with no cleanup in the loop. |
| CI | `.github/workflows/eval.yml` | Runs the suites on a clean macOS runner, optionally publishing. |
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
  "must_contain": ["PR"],              // case-insensitive, word-boundary
  "must_not_contain": ["Best,", "Dear"],
  "must_contain_exact": ["PR"],        // case-SENSITIVE; optional
  "must_not_contain_exact": [],
  "note": "casual Slack, no email chrome"
}
```

Rules:

- Audio cases **must** have `asr_reference`.
- `must_contain` / `must_not_contain` are case-insensitive checks on the **final**
  `llm_output` (or the deterministic fallback if the guard rejected). **A term made
  only of word characters matches on word boundaries; anything else is a plain
  substring.** So `"um"` means the word *um* and not the middle of "n-um-ber",
  while `"\n- "`, `"1."`, `"Best,"`, `"$25"` and `"github.com/corkkam"` mean
  exactly the characters they name. Two consequences worth knowing before you
  write a case:
  - **An inflection is a different word.** `"PR"` is found in "the PR" and not in
    "PRs". Spell the suffix out if you want the looser reading.
  - **To assert casing, use `must_contain_exact` / `must_not_contain_exact`.**
    The ordinary lists lowercase both sides, so `vocab-preserve` wanting
    "Parakeet" passes on "parakeet" — which is the defect the exact form found.
    Both exact lists follow the same word-boundary rule and default to empty, so
    a case that does not opt in means what it always meant. Don't reach for a
    first-letter-dropped stem (`'arakeet'`) to work around capitalization — it
    was never needed, and it stops matching entirely under word boundaries.
  - `eval-score` prints every assertion the two matchers read differently, so a
    term that was load-bearing on the old behaviour is visible rather than silent.
- The guard verdict is **not** a pass/fail. A rejection means the safe
  deterministic text was kept — for a faithfulness case that is often the
  correct result. An unfaithful *acceptance* is still caught by `must_not_contain`.
- `reference` is optional and **diagnostic**: it is one acceptable answer, not
  the only one, so a non-zero reference WER is information rather than a failure.

---

## Continuous metrics

`must_contain` answers "did the one thing we thought to assert happen", and it is
blind to everything else in the output. The long-form truncation of 2026-08-21 is
the case in point: a 525-word input came back as 207 words with the body gone and
**every keyword rule still passed**, because the anchors that survived were the
ones the case named.

So `eval-score` also reports the *shape* of each output. None of these is a
pass/fail criterion — a retention of 0.4 is wrong for a normalizer and right for
a Slack summary, and the band belongs to the target, not to the metric. They are
reported, aggregated per target, and compared run to run.

| metric | what it is | what a bad value means |
|---|---|---|
| **retention** | output words ÷ deterministic-input words | `< 1` dropped content, `> 1` padded it. This is the number that names a truncation. |
| **edit rate** | word edit distance from the LLM's input, over its length | `0` means the model changed nothing — the deterministic passes did the whole job and the case is not evidence for the model at all. High means it rewrote. |
| **novel-word rate** | share of output word *types* that were never said | The quantitative reading of "did it invent something", where the guard gives only accept/reject. |
| **guard fallback rate** | share of rows where the guard discarded the LLM output | How often a user gets no benefit from the model. Not a failure; still worth knowing. |
| **ms/word** | LLM ms ÷ input words | The honest latency figure. A 500-word case at 3 s and a six-word case at 70 ms are the same speed; a raw median over mixed lengths hides which one moved. |
| **reference WER** | output vs the case's `reference`, when it has one | Divergence from the ideal. Diagnostic. |
| **no-op rows** | count of rows with edit rate 0 | If most of a target's rows are no-ops, that target is paying latency for nothing. |

**Novel words exclude the transformations the pipeline is built to make** —
digit runs (inverse text normalization: "twenty five" → "$25"), joined
initialisms ("a p i" → "api"), apostrophe variants, and function words. An
invented *fact* is never a closed-class word, so excluding grammar costs no
detection and removes almost all of the false positives. That is why the number
can be read directly instead of eyeballed. The known over-count, left in the
open: a **content-word** rephrase a rephrasing target is allowed to make
("purchase" for "buy" under `polish`) reads as novel — which is why the metric is
compared within a target and never gated on.

`eval-score` closes with a **"passed the rules, worth a look"** list: rows that
satisfy every keyword rule and still have a retention outside 0.75–1.6 or a novel
word. That list is the point of all of this — with two exemptions, both of which
came from the list being 16 entries of which 13 were correct outputs:

- **`disfluency` and `fillers` are exempt from the retention floor.** A collapsed
  restart is *supposed* to lose words: "ship it friday actually no let me start
  over we should ship it monday" → "We should ship it Monday" is retention 0.40
  and the best output in the suite.
- **The novel-word check applies to non-rephrasing targets only.** `polish`
  writing "went" for a tense fix is its job; `light` inventing a word is the
  finding.

A list that is mostly noise gets skipped, which costs more than the two
exemptions do.

### Severity weighting

A weighted pass rate is printed beside the raw one, never instead of it. A
normalizer that answers a dictated question or mangles a spoken password has
broken the promise the product is sold on; one that misses an acronym has been
mildly annoying — and an unweighted count calls those one failure each. Weights
live in `Scorer.categoryWeight` (`faithfulness` and `sensitive` ×3;
`long-form`, `realistic`, `multilingual`, `idempotency` ×2; `uri` ×1.5;
`disfluency` ×1.5; everything else ×1) and are mirrored in the dashboard's
`CATEGORY_WEIGHT`.

### Per-category roll-up

`category` is on every case and used to be rolled up nowhere, so a suite-wide
"174/178" could hide a whole category going red while `numbers` carried the
total. `eval-score` now prints a pass rate per category, marking any that is not
clean. It is the cheapest real signal in the scorer.

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
5. Pushes to `whisper.corkkam.com/eval` unless `NO_PUSH=1`.

Useful env:

| var | default | meaning |
|---|---|---|
| `APP` | `/Applications/Whisper Master.app` | Which bundle to launch |
| `OUT` | `eval/text-cleanup/.eval-scratch/results.json` | Where `results.json` lands |
| `DASHBOARD_URL` | `https://whisper.corkkam.com` | Ingest target (`http://localhost:3000` for a local landing site) |
| `EVAL_INGEST_TOKEN` | unset | Required by the ingest route, which fails closed |
| `EVAL_VERSION` | unset | Marketing version this run grades (release.sh sets it) |
| `EVAL_CHANNEL` | unset | stable / beta / dev (release.sh sets it) |
| `TIMEOUT` | `1200` | Seconds to wait for the write |
| `NO_PUSH=1` | off | Skip the push |

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

Prints `total / pass / fail`, per-target pass rate (raw **and** weighted),
median/p90/p99 latency plus ms/word, the continuous metrics above, the
per-category roll-up, every failing id with reasons and `asr` vs `cleanup`
attribution, and the "passed the rules, worth a look" list. Tweak a
`must_contain` and re-run this — you do not need the LLM again.

`--json` emits the same roll-up as one machine-readable object, which is what a
CI step should read rather than parsing the text:

```bash
swift run eval-score results.json cases.jsonl --json | jq '.targets.light'
```

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
3. **Each row has** `id`, `category`, `target`, `input_kind`, `deterministic`,
   `llm_output`, `guard.accepted`, `latency_ms`. Audio rows also have `asr_text`
   / `asr_reference`. (`category` was added 2026-08-22; a run from an older
   bundle lacks it, and the scorer and the dashboard both fall back to the
   category in the cases file.)
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

## Where the history lives

Public history: **[whisper.corkkam.com/eval](https://whisper.corkkam.com/eval)**, served by
the landing site (`../whisper-master-landing-page`, route `app/eval/`, data in
`lib/eval/` on Supabase).

The old SvelteKit dashboard that used to live at `eval/dashboard/` **has been
deleted**. Its eval half moved here; its `/api/usage` and `/api/notes` routes
moved to the landing site, and `UsageSyncConfig` / `NotesSyncConfig` now point
at `whisper.corkkam.com`. The Vercel project at `whisper-eval-dashboard.vercel.app`
still has to stay deployed until 1.1.0-beta.7 and .8 age out, because those
builds have the old URL compiled into them; nothing in this repo depends on it
any more.

A run is published by `run-eval.sh`, or by hand:

```bash
EVAL_INGEST_TOKEN=… node eval/text-cleanup/push-run.mjs \
  eval/text-cleanup/.eval-scratch/results.json \
  eval/text-cleanup/cases.jsonl "light+polish"
```

Reads are public; `POST /api/eval/ingest` needs a matching `x-ingest-token` and
refuses every upload when the token is unset. `lib/eval/scoring.ts` in the
landing repo is a port of `EvalScoreKit` — keep them in sync if you change a
scoring rule, or the published number stops matching `eval-score`.

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
