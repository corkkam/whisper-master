# Eval dashboard redesign — design

**Date:** 2026-07-06 · **Component:** `eval/dashboard/` (SvelteKit + Prisma + MongoDB)

## Problem

The eval dashboard is going **public**. Its current UI leans on a "copyeditor's
proof sheet" metaphor — "the ear", "the pen", proofreading marks, monospace
everywhere — plus raw jargon (WER, guard, attribution) with no explanation. It
assumes the viewer already knows what an ASR/cleanup eval is, so even technical
visitors can't tell what they're looking at. It also fetches everything via
server `load` with no pagination, so a growing run history and 89–260-case runs
become unwieldy.

## Goal

A public page that, in one scroll, tells a layered story:

- **A — trust:** "this dictation cleanup is accurate and safe" (headline numbers).
- **B — credibility:** "here's how we test it, and how it's improving over time."
- **C — proof:** "here's exactly what it does to real speech, case by case."

Everything a non-expert needs is explained inline; every number is in plain
words before it is in jargon.

## Non-goals

- **Scoring logic does not change.** `src/lib/scoring.ts` (the TS port of the
  Swift `EvalScoreKit`) keeps identical logic — the numbers must stay the same.
  This is a presentation + data-fetching redesign only.
- No auth, no write UI (ingest stays API-only via `scripts/push-run.mjs`).
- No new metrics; we re-present the ones we already store.

## Audience & narrative (single scrolling home page)

1. **Hero + 3 trust numbers (A).** A plain one-liner: "How well does Whisper
   Master clean up your dictation? We grade the **real, shipped** pipeline on
   every change — here's the evidence." Then three big stat cards, plain-worded:
   - **Cleanup accuracy** — text pass rate (e.g. "94% of cleanup cases pass").
   - **Transcription accuracy** — LibriSpeech mean WER, phrased "hears real human
     speech at 3.4% word error."
   - **Faithfulness** — "never answers, obeys, or invents — N adversarial cases
     held." Numbers come from the latest run.
2. **"How we test" strip (B).** Four tiny steps: real speech in → the actual app
   pipeline (not a proxy) → graded on keyword rules + word-error-rate + a
   faithfulness guard → Claude judges subjective quality. Each jargon term is
   defined inline the first time it appears (WER → "word error rate: the % of
   words misheard").
3. **Trend (B).** Pass-rate across runs over time, plain axis labels, and a
   one-sentence "what up means here."
4. **Runs list (paginated).** date · label · pass rate · LibriSpeech WER ·
   commit → links to the run detail.

## Type & visual system

Keep the warm "Daylight" brand — cream paper, vermillion accent, dark-mode
support — but replace the monospace-everywhere type with a real system:

- **Headlines:** **Fraunces** (warm, characterful serif — signals editorial
  rigor).
- **Body / UI / numbers / labels:** **Inter**.
- **Transcripts only:** **JetBrains Mono** (the before/after case text).

Fonts are self-hosted via `@fontsource` packages (no external network requests —
faster, private, works offline). Existing CSS custom properties in `app.css`
(`--paper`, `--ink`, `--pen`, etc.) are kept; `--sans`/`--mono` are repointed and
a `--display` var is added. Monospace is used **only** inside `.txt` transcript
blocks; chips, tags, stats, and labels move to Inter.

## Run detail page

- **Plain header:** label, date, "84% of cases passed", commit/branch tags.
- **Two sections with plain-English headings** replacing "the ear / the pen":
  - **"Did it hear the words right?"** — WER by source, with human labels (Real
    human speech / Synthetic / Bluetooth mic / Noisy room), the %, and a
    one-line reading ("near-perfect on real speech; noise is the hard case").
  - **"Did it clean up correctly and safely?"** — pass rate, faithfulness split,
    latency (median/p90), and the ASR-vs-cleanup attribution.
- **Cases (paginated / load-more, mobile-first):** each case a card — input →
  cleaned-output diff (proofreading marks kept, they read well), plain PASS/FAIL,
  a one-line "why" (the failing rule, or "kept safe: guard rejected the answer").
  Filter by outcome/source + text search, applied to the paginated query.

## Data layer — SSR-hybrid TanStack Query

Per `@tanstack/svelte-query` v5 SSR guidance (context7):

- **Root layout** (`+layout.ts` + `+layout.svelte`): create one `QueryClient`
  with `defaultOptions.queries.enabled = browser` (so queries don't run twice on
  the server), wrap the app in `QueryClientProvider`.
- **JSON API endpoints** (Prisma stays server-only behind them):
  - `GET /api/runs?page=&pageSize=` → `{ runs, total, page, pageSize }`.
  - `GET /api/runs/[id]` → run summary + aggregate.
  - `GET /api/runs/[id]/cases?page=&pageSize=&outcome=&source=&q=` → paginated,
    filtered case rows.
- **SSR prefetch:** each route's `load` calls `queryClient.prefetchQuery(...)`
  for page 1 so first paint is server-rendered and shareable; the component uses
  `createQuery` with the **same query key** (reads from cache, no refetch).
- **Pagination:** `createQuery({ queryKey: ['runs', page], queryFn,
  placeholderData: keepPreviousData })`; `isPlaceholderData` disables the
  next/prev buttons until data arrives (flash-free paging).
- **Ingest** (`POST /api/ingest`) is unchanged.

### API/query shape notes

- Endpoints reuse `src/lib/server/runs.ts`; add `listRuns(page, pageSize)` +
  `total` count and a `getRunCases(id, {page, pageSize, filters})`. Scoring is
  applied at read time from stored rows exactly as today (no re-score drift).
- Query keys: `['runs', page]`, `['run', id]`, `['run', id, 'cases', {page,
  filters}]`.

## Component structure (small, single-purpose)

`StatCard`, `HowItWorks`, `TrendChart` (reworked), `RunRow`, `Pagination`,
`WerBars`, `OutcomeTiles`, `CaseCard`, `DiffText` (kept), `MetricLegend`,
`Explainer`/inline `<Term>` for jargon tooltips. Each ≤ ~150 lines, one job.

## Best practices / cross-cutting

- **Mobile-first responsive** — public viewers are on phones; stat cards and
  case cards stack, the trend chart scrolls/scales.
- **Accessibility** — labelled controls, visible focus, `prefers-reduced-motion`
  respected, semantic headings for the narrative.
- **Dark mode** kept (existing `prefers-color-scheme` tokens).
- **Verification:** `npm run check` (0 errors), `npm run build` (adapter-node),
  serve + click through home → run → paginate cases; re-push a run and confirm
  the numbers match the CLI `eval-score` (scoring parity). No app rebuild needed
  (dashboard-only).

## Rollout

Feature work stays in `eval/dashboard/` on the `eval-engine` branch. `.env`,
`node_modules`, build output remain gitignored. `report.html` (the standalone
static viewer) is left as-is for now; it can be regenerated from the new tokens
later if desired (out of scope here).
