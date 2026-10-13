---
name: eval-pipeline
description: Run and interpret the Whisper Master text-cleanup evaluation — the in-app EvalRunner, eval-score/EvalScoreKit scoring, cases.jsonl authoring, audio case generation, and the SvelteKit/Prisma run-history dashboard on Vercel. Use when running an eval, changing the cleanup pipeline, or working under eval/.
---

# Evaluation engine

### Evaluation engine (`eval/text-cleanup/`)

A quality-first eval for the cleanup pipeline, split by the nature of the code:
**durable logic is Swift, disposable glue is shell, Codex is the judge.**
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
  schema loader, `WER`, `Scorer`) + CLI (`swift run eval-score <results.json>
  <cases.jsonl>`). Objective scoring only: keyword `must_contain`/`must_not_contain`
  + WER threshold, with failures attributed to **ASR vs cleanup**. The **guard
  verdict is diagnostic, not a pass/fail criterion** (Swift `Scorer` + the
  dashboard `scoring.ts` port, kept in sync): a guard *rejection* means the safe
  deterministic fallback was used, and for a faithfulness case that fallback is
  the correct result that satisfies the keyword rules — so it must not be marked
  failed; an unfaithful *acceptance* is still caught by `must_not_contain`. Unit
  tests: `swift test --filter EvalScoreKitTests`.
- **Codex is the judge.** After a run, Codex reads `results.json` and writes
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
- **Run history + public dashboard (`eval/dashboard/`):** a SvelteKit + Prisma 6 +
  MongoDB Atlas app that stores runs over time and renders them for a **public**
  audience. `src/lib/scoring.ts` is a TS port of `EvalScoreKit` so runs score
  identically (guard verdict diagnostic, as above).
  - **Deployed on Vercel** (`@sveltejs/adapter-vercel`, nodejs20.x) at
    **https://whisper-eval-dashboard.vercel.app**; the GitHub integration
    **auto-deploys from `dev`** (Vercel project **Root Directory = `eval/dashboard`**
    + an ignored-build-step `git diff --quiet HEAD^ HEAD -- .` so it only rebuilds
    when the dashboard changes). Manual redeploy: `vercel --prod` from
    `eval/dashboard`. **`dev` must carry the `adapter-vercel` + auth commits** or a
    deploy builds wrong/unsecured.
  - **Prisma on Vercel:** `binaryTargets = ["native","rhel-openssl-3.0.x"]` in
    `schema.prisma`, and `build` runs `prisma generate` first (Vercel caches deps
    and can skip postinstall).
  - **Env** (Vercel prod+preview *and* local `.env`): `DATABASE_URL` — any Atlas
    cluster is a replica set, but **the SRV string must include a db name in the
    path** (`…mongodb.net/evaldash?…`) or Prisma rejects it P1013 — and
    `INGEST_TOKEN`.
  - **Reads are public; writes are not.** `POST /api/ingest` requires an
    `x-ingest-token` header equal to `INGEST_TOKEN` (else 401); `push-run` sends it
    (from the env or the dashboard `.env`).
  - **Data:** SSR-hybrid **`@tanstack/svelte-query` v6** (runes) — `load` SSRs page 1
    as `initialData`, the client paginates with `keepPreviousData` against
    `GET /api/runs?page=` and `GET /api/runs/[id]/cases?page=` (Prisma stays behind
    those endpoints). UI matches the app's **light-only Daylight** theme (white
    canvas, brick `#c0381a`; Fraunces/Inter, mono for transcripts only); the home
    hero is a rotating real before/after "watch it work" demo + a pipeline flow.
  - **Ingest is not automatic:** after an eval writes `results.json` it must be
    pushed — one-shot `eval/text-cleanup/run-eval.sh [cases.jsonl] [label]`
    (launches the app via `launchctl setenv` + `open`, waits for `results.json`,
    pushes; `DASHBOARD_URL` retargets to prod, `NO_PUSH=1` skips). `push-run` is the
    manual equivalent. Local dev: `npm run db:push` then `npm run dev`.
