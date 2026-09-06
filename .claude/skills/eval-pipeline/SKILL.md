---
name: eval-pipeline
description: Run and interpret the Whisper Master text-cleanup evaluation — the in-app EvalRunner, eval-score/EvalScoreKit scoring, cases.jsonl authoring, audio case generation, the per-release grading hook in Scripts/release.sh, and the public run history at whisper.corkkam.com/eval. Use when running an eval, changing the cleanup pipeline, cutting a release, or working under eval/.
---

# Evaluation engine

### Evaluation engine (`eval/text-cleanup/`)

A quality-first eval for the cleanup pipeline, split by the nature of the code:
**durable logic is Swift, disposable glue is shell, Claude Code is the judge.**
Spec + plan: `docs/superpowers/specs/2026-07-06-eval-engine-design.md`,
`docs/superpowers/plans/2026-07-06-eval-engine.md`.

- **Grade the real pipeline, never a proxy.** `Sources/WhisperMaster/Eval/EvalRunner.swift`
  is a dev-only in-app runner: set `WM_EVAL_CASES=<cases.jsonl>` (+ optional
  `WM_EVAL_OUT`), launch the built app **via LaunchServices (`open`), not the raw
  binary**, and after the MLX model loads it runs every text case through the
  shipped deterministic passes (`TranscriptSpacingRepair` → `SelfCorrectionCollapser`
  → `DeterministicITN` → `FillerWordFilter` → `VocabularyPostProcessor`) + every
  requested `CleanupTarget` (`light`, `polish`, and eval-only `slack`/`email`/`code`)
  with the **real** `CleanupFaithfulnessGuard`, grouped by target so the
  KV cache stays primed, and writes `results.json` (per-stage outputs, guard
  verdict, per-stage latency). **Directly exec'ing the bundle's Mach-O crashes**
  (TCC can't find the Info.plist usage strings → the mesh CoreBluetooth scan hard-
  crashes); pass env vars to `open` via `launchctl setenv`.
- **`eval-score`** — a dependency-free SwiftPM library (`EvalScoreKit`: `EvalCase`
  schema loader, `WER`, `Scorer`, `Metrics`) + CLI (`swift run eval-score
  <results.json> <cases.jsonl> [--json]`). Objective scoring only: keyword
  `must_contain`/`must_not_contain` + WER threshold, with failures attributed to
  **ASR vs cleanup**.
  - **Beside the verdict it reports the *shape* of every output** (`Metrics`):
    retention, edit rate, novel-word rate, guard fallback rate, ms/word,
    reference WER, no-op rows — plus a per-category roll-up and a
    severity-weighted pass rate. **None of them is a pass/fail criterion**; the
    band belongs to the target, not to the metric. They exist because a keyword
    rule only sees what somebody thought to assert: the 2026-08-21 long-form
    truncation dropped three fifths of a 525-word input and **passed every
    rule**, and a retention of 0.40 is what says so without anyone having written
    an assertion for the missing sentence. The CLI closes with a **"passed the
    rules, worth a look"** list built from exactly that.
  - **`Metrics.novelWords` excludes what the pipeline is built to do** — digit
    runs (ITN), joined initialisms ("a p i" → "api"), apostrophe variants, and
    function words. An invented *fact* is never a closed-class word, so excluding
    grammar costs no detection and kills nearly every false positive. **Do not
    replace the enumerated contraction list with a substring test**: the version
    that did excluded "paris" because it contains "is", and `MetricsTests` locks
    the case that caught it. The **guard
  verdict is diagnostic, not a pass/fail criterion** (Swift `Scorer` + the
  `lib/eval/scoring.ts` port on the landing site, kept in sync): a guard *rejection* means the safe
  deterministic fallback was used, and for a faithfulness case that fallback is
  the correct result that satisfies the keyword rules — so it must not be marked
  failed; an unfaithful *acceptance* is still caught by `must_not_contain`. Unit
  tests: `swift test --filter EvalScoreKitTests`.
- **Claude Code is the judge.** After a run, Claude reads `results.json` and writes
  `judgment.md` (faithfulness + quality per target, light-vs-polish, latency,
  recommendations) — the subjective call keyword rules can't make. No API key, no
  sub-agents.
- **Cases** (`cases.jsonl`, generalized schema: `input:{text|audio}`, `targets`,
  `reference`, `asr_reference`, keyword rules). `targets` is the extension hinge:
  `light`+`polish` ship; `slack`/`email`/`code` are eval-only destinations
  (à la Wispr Flow) in `CleanupTarget` + `flow-cases.jsonl`. Adding another
  destination is a case on the enum + a prompt + cases that list it.
  Audio cases are generated into git-ignored `.eval-scratch/` by two scripts:
  `make_audio.sh` (TTS every text case via `say`; ffmpeg-gated Bluetooth-HFP +
  pink-noise augmentation for the realistic/disfluency subset) and
  `fetch_librispeech.sh` (a slice of **LibriSpeech dev-clean**, openslr.org
  CC BY 4.0, the real-human WER anchor — the tarball is fetched, sliced, and
  deleted). `ffmpeg` (Homebrew) is required only for augmentation + LibriSpeech
  flac→m4a.
- **Findings so far** (`judgment.md`): Parakeet is near-perfect on real clean
  speech (**3.4% mean WER** on LibriSpeech); the ASR bottleneck is **noise
  (23.5%) and Bluetooth-HFP (16.3%)**, not clean-condition hearing. The
  experimental `polish` mode originally **answered questions** ("capital of
  france" → "…Paris") — fixed by an anti-answer rule in the guard (reject a
  mid-sentence capitalized entity the input never had); `polish` stays
  off-by-default/experimental regardless.
- **Run history + public page (`whisper.corkkam.com/eval`):** served by the
  landing-page repo (`../whisper-master-landing-page`), route `app/eval/`, data
  in `lib/eval/` on the shared **Supabase** project (`eval_runs` /
  `eval_results`, migration `0010`). `lib/eval/scoring.ts` there is a TS port of
  `EvalScoreKit` so runs score identically (guard verdict diagnostic, as above);
  it is verified against the stored history and matches exactly.
  - **Reads are public; writes are not.** `POST /api/eval/ingest` requires an
    `x-ingest-token` header equal to `EVAL_INGEST_TOKEN` and **fails closed** —
    with the token unset every upload is refused (503), not accepted. The token
    is a Vercel **production** variable, a GitHub Actions secret on this repo,
    and a line in this repo's `.env`. Deliberately **not** set on Vercel preview,
    so a preview deployment cannot publish a run.
  - Eval reads are pinned to the Supabase `public` schema in every environment,
    unlike the rest of that app, which reads `dev` on preview. There is no such
    thing as the preview's eval history.
  - **Every release grades itself.** `Scripts/release.sh` runs the text suite
    against the bundle it just built and pushes the scores tagged with
    `EVAL_VERSION` and `EVAL_CHANNEL`, so `/eval` can answer "how did
    1.1.0-beta.9 score". On for **stable and beta**, off for `dev`;
    `RUN_EVAL=0`/`1` overrides, `EVAL_REQUIRED=1` makes it a gate. It runs last
    and is non-fatal by design — a flaky twenty-minute eval must not be able to
    skip the DMG, the What's New manifest, or the release tag.
  - **A run pushed with the wrong rules file scores higher, silently.** A case
    with no `must_contain`/`must_not_contain` entry can only fail on word error.
    The audio suite's ids are prefixed (`tts-`, `hfp-`, `noisy-`, `ls-`) and
    exist only in the generated `.eval-scratch/audio_cases.jsonl`; pushing an
    audio run with the baseline `cases.jsonl` turns 77/140 into 87/140 and drops
    all 19 cleanup-attributed failures. The ingest route now returns how many
    cases carry no rule and `push-run.mjs` prints a warning.
  - **Ingest is not automatic outside a release:** after an eval writes
    `results.json` it must be pushed — one-shot
    `eval/text-cleanup/run-eval.sh [cases.jsonl] [label]` (launches the app via
    `launchctl setenv` + `open`, waits for `results.json`, pushes; `DASHBOARD_URL`
    retargets, `NO_PUSH=1` skips). `eval/text-cleanup/push-run.mjs` is the manual
    equivalent.
  - **The old SvelteKit dashboard (`eval/dashboard/`) is retired for eval.** It is
    still deployed at `whisper-eval-dashboard.vercel.app` and must stay up:
    shipped Mac builds hardcode it as the base URL for `/api/usage` and
    `/api/notes` (`Usage/UsageSyncConfig.swift`, `Notes/NotesSyncConfig.swift`).
    It is on a **different Vercel account**, so its Mongo `DATABASE_URL` cannot be
    read with the CLI on this machine — which is why the history was moved to
    Supabase rather than re-pointed at Atlas. Do not push runs there; do not add
    features there.
  - **The scorer's own semantics changed on 2026-08-23 and the port has to follow.**
    A `must_contain` term of word characters now matches on **word boundaries**
    (`Scorer.matches`), because a substring found the forbidden filler `"um"`
    inside "number" and "documentation". `lib/eval/scoring.ts` on the landing site
    must carry the same `matches` and the same `novelWords` / `rowMetrics` /
    `CATEGORY_WEIGHT` / `percentileIndex`, or the page scores a stored run
    differently from the `eval-score` output that produced it. The new
    `Aggregate` fields are **optional on read**: runs ingested before that date
    lack them, and a missing measurement must not render as a measurement of
    zero. `category` and `reference` come from the **cases file**, not only from
    `results.json` — the runner has only just started writing `category` and it
    never writes `reference`.
