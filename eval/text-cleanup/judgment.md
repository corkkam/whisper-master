# Judgment — S1-mini replaces qwen2.5-3B for cleanup

Run: 2026-08-21. Model under test: **S1-mini by Superwhisper**, 4-bit MLX (335 MB on
disk), against the outgoing **qwen2.5-3B-Instruct-4bit** (1.5 GB). Both measured
through the real app (`EvalRunner`), deterministic passes feeding the model, the real
`CleanupFaithfulnessGuard` vetting the output, scored by `eval-score`.

## Text — 89 cases

| pipeline | shipped | median LLM | p90 | size |
|---|---|---|---|---|
| deterministic only | 67/89 | 0 ms | 0 ms | — |
| + qwen2.5-3B | 85/89 | 248 ms | — | 1.5 GB |
| **+ S1-mini** | **87/89** | **102 ms** | 177 ms | **335 MB** |

`eval-score`: `total 178, pass 174, fail 4` — `light 87/89`, `polish 87/89`,
attribution `asr 0, cleanup 4`. The four are two distinct cases across both targets:

- **`vocab-acronym`** — "our a p i is getting rate limited" does not become "API".
  The 3B missed this too.
- **`corr-name-chain`** — "call john no jane no actually mike". Already documented in
  `CLAUDE.md` as a known limitation that a small model does not solve; the guard
  rejects and the deterministic text ships, which is the correct failure mode.

**Verdict on text: better than the model it replaces, on a quarter the disk and under
half the latency.** No regression found.

## Audio — 121 cases (89 TTS + 32 augmented: Bluetooth-HFP, pink noise)

`eval-score`: `total 240, pass 122, fail 118`, attribution **`asr 104, cleanup 14`**.

The headline pass rate is not a cleanup result — 104 of 118 failures are the ASR
failing on synthetic `say` speech, which is consistent with the standing finding that
Parakeet is near-perfect on real speech and struggles with noise and HFP. **The 14
cleanup-attributed failures are three distinct cases**, and none is a regression:

1. **`corr-name-chain`** (6 rows: 3 conditions × 2 targets) — the known limitation
   above. Guard rejects, deterministic ships.
2. **`real-email`** (6 rows) — asserts `must_not_contain: "um"`, and the ASR emitted
   **`UM`** in capitals. `FillerWordFilter` spares all-caps tokens **deliberately**
   ("'ER', 'UM' etc. spoken as initialisms come through all-caps; a real filler never
   does"). S1-mini then kept it, which is correct behaviour for a normalizer. This is
   the eval case colliding with an intentional rule, not a defect — **do not "fix" the
   filter here**, it would break initialism protection.
3. **`caps-proper`** (2 rows) — the ASR heard "**Sarai**", not "Sarah", and the
   deterministic text already said Sarai. S1-mini faithfully preserved it. Mis-attributed
   as cleanup because the single-word WER fell under threshold; it is an ASR miss, and
   a normalizer that "corrected" a name it had not heard would be the worse outcome.

**Verdict on audio: no cleanup regression attributable to S1-mini.**

## LibriSpeech — 20 clips of real human speech (dev-clean, CC BY 4.0)

`eval-score`: `total 20, pass 19, fail 1`, attribution **`asr 1, cleanup 0`**. The one
failure is a 40% WER clip; every cleanup pass held.

Mean WER **3.4%**, median **0.0%**, 15/20 under 5% — **identical to the figure on
record before this change**, which is the check that matters here: the swap touched
the cleanup model only, and the ASR anchor did not move.

**Verdict on real speech: zero cleanup failures.**

## Not verified

- **The R2 install path.** The archive is published and publicly fetchable
  (`models/s1-mini-4bit.zip`, 293 MB, `206` on a range request), and `ModelInstaller`
  resolved the correct URL into `.downloads/index.json` — but the background transfer
  never started in a five-minute observation window, so unpack-and-install has not been
  seen end to end. `EvalRunner` cannot cover this: it calls
  `MlxCleanupService.prepare(configuration:directory:)` and bypasses `ModelInstaller`
  entirely. **This is the one open item before shipping.**
- **Non-English.** S1-mini is English-only (v1). Parakeet v3 is multilingual. What the
  normalizer does with non-English input is unknown and untested, and the failure would
  be silent. Worth gating before Smart cleanup is ever made on-by-default.

## Recommendation

Adopt. It is better on every axis measured, and the two remaining text failures were
already failing. Before turning Smart cleanup **on by default** — which 335 MB and
100 ms otherwise justify — close the install path and decide the non-English question.
