# Eval dashboard

A small full-stack app that stores **eval runs over time** and renders them as a
proof sheet — so you can watch pass rate, WER, and latency move as prompts and
guards change, instead of eyeballing one `results.json` at a time.

**Stack:** SvelteKit (adapter-node) · Prisma 6 · MongoDB (Atlas). Svelte 5 runes,
TypeScript, no runtime UI dependencies. Pure scoring logic (`src/lib/scoring.ts`)
is a faithful port of the Swift `EvalScoreKit`, so a run is scored here exactly
as `eval-score` scores it.

## Why SvelteKit full-stack (not SvelteKit + Hono)

The frontend and the API are the same product — an internal dashboard. SvelteKit
gives server endpoints (`+server.ts`) and server `load` in one deployable, so a
separate Hono service would add moving parts without buying separation we need.
Prisma runs in `src/lib/server/*`, which is server-only by SvelteKit's contract.

## Setup

```bash
cd eval/dashboard
npm install                 # installs deps + generates the Prisma client
cp .env.example .env        # then set DATABASE_URL to your MongoDB Atlas cluster
npm run db:push             # create the collections (Mongo has no migrations)
npm run dev                 # http://localhost:5173
```

> `DATABASE_URL` must point at a **replica set** — every Atlas cluster is one, so
> the Atlas SRV string works as-is. Prisma 6 needs no driver adapter for MongoDB.

## Storing a run (history)

**One command — run the eval and push it in one shot** (recommended):

```bash
# dev server running on :5173, from eval/text-cleanup
bash run-eval.sh                         # cases.jsonl, auto-labelled
bash run-eval.sh cases.jsonl "my label"  # explicit
```

`run-eval.sh` launches the app for the eval, waits for `results.json`, then
pushes it here automatically. `NO_PUSH=1` runs the eval only; `DASHBOARD_URL`
retargets the push.

**Or push an existing `results.json` manually:**

```bash
# dev server running on :5173
npm run push-run -- ../text-cleanup/.eval-scratch/results.json ../text-cleanup/cases.jsonl "text run"
```

`push-run` posts to `POST /api/ingest`, which scores every row (keyword rules +
guard verdict + WER), computes the aggregate, and stores a `Run` + its `Result`
rows. It stamps the current git commit + branch automatically. Override the
target with `DASHBOARD_URL`.

The API is language-agnostic — anything that can POST JSON can feed it:

```
POST /api/ingest
{ "results": <results.json array>, "cases": "<cases.jsonl text>",
  "label": "…", "gitCommit": "…", "branch": "…" }
```

## What you see

- **`/`** — run history: a pass-rate trend across runs, then the list, each with
  light/polish pass counts, case counts, and LibriSpeech WER.
- **`/runs/[id]`** — the proof sheet for one run: the ear (WER by source) vs the
  pen (pass rate + latency + asr/cleanup attribution), then every case marked up
  word-by-word (deterministic → light → polish, edits in red pen), filterable by
  verdict/source and searchable.

## Layout

```
prisma/schema.prisma            Run + Result models (mongodb)
src/lib/scoring.ts              WER + scorer + aggregate (pure, port of EvalScoreKit)
src/lib/diff.ts                 word diff -> proofreading marks
src/lib/types.ts                DTOs + groupByCase
src/lib/server/db.ts            Prisma client singleton
src/lib/server/ingest.ts        parse + score a results.json into a storable run
src/lib/server/runs.ts          create / list / get / delete runs
src/lib/components/*.svelte      WerBars, OutcomeTiles, CaseCard, DiffText, TrendChart
src/routes/+page.*               history + trend
src/routes/runs/[id]/+page.*     one run's proof sheet
src/routes/api/ingest/+server.ts POST ingest
scripts/push-run.mjs            CLI: post a results.json into history
```

## Build / deploy

```bash
npm run check      # svelte-check, 0 errors
npm run build      # adapter-node -> ./build
node build         # production server (PORT, default 3000)
```
