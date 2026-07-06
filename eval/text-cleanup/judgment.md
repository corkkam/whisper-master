# Eval judgment — first run

**Date:** 2026-07-06 · **Cases:** 89 (text) · **Targets:** light, polish · **Model:** qwen2.5-3B-4bit (MLX, real pipeline)

## Headline

Mechanical: **178 runs, 134 pass, 44 fail.** But read the fails carefully — many
are the guard *correctly* rejecting a bad LLM output and falling back to the
deterministic text (safe behavior, scored as "fail" only because a `must_contain`
wasn't met by the raw fallback). The important signal is qualitative, below.

**Latency (LLM stage, real):** light median **346 ms** / p90 648 ms; polish
median **403 ms** / p90 901 ms. Polish costs ~57 ms median, ~250 ms p90 over
light. Both comfortably sub-second — latency is not the problem.

## Critical finding: polish mode breaks faithfulness

- **`grammar-faithful-question-01`**: "what is the capital of france"
  → polish: **"The capital of France is Paris."**
  Polish **answered the question**. This is the one thing cleanup must never do.
  Light correctly left it unanswered.
  **Root cause:** the `allowRephrase` guard's novel-content cap (0.5) is too
  loose here — of {capital, france, paris}, only "paris" is new = 1/3 < 0.5, so
  it passes. The relaxation I added for polish went too far.

## Polish quality issues

- **`grammar-agreement-01`**: "me and him was gonna go"
  → polish: **"I and him were going to go"** — grammatically wrong ("I and him";
  should be "He and I"). Polish tried to fix agreement and got the pronoun wrong.
- **`grammar-numbers-keep-01`**: → polish: **"The budget is $75,000 for Q3, not
  $50,000."** Polish **invented** "not $50,000", re-surfacing the value the
  speaker corrected away.

## Where polish genuinely helps

- **`grammar-runon-01`**: run-on → two clean sentences, meaning preserved.
- **`grammar-tense-01`**: "yesterday i go … i see" → **"Yesterday, I went to the
  office and saw the new design."** Correct tense; light left this one unchanged.

## Light mode gap

- Light often leaves text **unchanged** on grammar/tense inputs (guard rejects
  the light output, falls back to raw) — e.g. it doesn't even capitalize
  `grammar-tense-01`. Conservative to a fault on some inputs.

## Recommendations (next loop round)

1. **Tighten the polish guard** — the novel-content-fraction cap can't catch a
   short answer like "…is Paris." Add a harder anti-answer rule for polish
   (e.g. reject any *new proper noun / capitalized entity* not in the input, or
   detect a question→statement flip). Re-measure `grammar-faithful-question-01`.
2. **Polish pronoun/agreement errors** ("I and him") are model-level; try a
   prompt example, or accept that a 3B model makes some.
3. **Light over-rejection** — investigate why light output is discarded on plain
   capitalization cases.

**Verdict:** the polish ("Polish my English") mode is **not safe to ship as-is** —
it answers questions. The eval did its job: it turned "something feels off" into
a specific, reproducible faithfulness break with a named root cause.
