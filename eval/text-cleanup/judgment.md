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

## Long-form: a truncation, and a guard that could not see it

Run: 2026-08-21, after the S1-mini adoption. A 525-word case
(`long-migration-update`) was added because nothing in the suite was long enough to
exercise the generation ceiling — the longest existing case is ~120 words.

`MlxCleanupService` caps a generation at 512 tokens against a runaway decode. At
~1.3 English tokens per word that is ~390 words of output. The same input was run
four ways:

| arm | out | ratio | old verdict | what it was |
|---|---|---|---|---|
| isolated, unchunked | 437w | 0.84 | **accepted** | stops on the word "We" |
| isolated, chunked | 496w | 0.95 | accepted | ends where the speaker did |
| full suite, unchunked | 207w | 0.40 | **accepted** | three fifths gone |
| full suite, chunked | 765w | 1.47 | **accepted** | one sentence, 19 times |

**The truncation is real and the chunker fixes it** — in isolation, 0.84 cut
mid-sentence becomes 0.95 complete, for ~300 ms. But the guard accepted every bad
output, which is the more serious finding: `minRetentionRatio` 0.30 and
`rephraseMaxExpansionRatio` 2.0 were tuned on six-word utterances, where a faithful
cleanup really can halve or double the count. They have no business judging 500 words.

Long inputs (≥120 words) now get 0.75 retention and 1.25 expansion. The
mid-sentence cut gets a **separate verdict** (`.cutOff`) rather than a tighter
floor, because 0.84 and 0.95 are too close for any ratio to separate — what makes
one wrong is *where it stops*. That test self-calibrates against S1-mini's casual
registers, which omit the final period deliberately.

Verified on the real pipeline: exactly **one** verdict flips against the previous
run (the 19× loop, now rejected); the other 91 cases are untouched.
`CHUNK_WORDS=0 bash run-eval.sh` is the control arm.

**Text after the change:** 180/184 — `light 90/92`, `polish 90/92`, attribution
`asr 0, cleanup 4`. The four are the two known cases (`vocab-acronym`,
`corr-name-chain`) across both targets. Latency unchanged: light 105 ms median,
polish 214 ms.

**Audio after the change:** 244 rows, `asr 110, cleanup 14` — **the cleanup count is
identical to the pre-change run**, and the same three cases
(`real-email`, `corr-name-chain`, `caps-proper`). No regression. Parakeet
transcribed the full 3.5-minute recording of the long case intact, which is the
first time the streaming path has been asked for 500 words.

### ⚠️ Still open: long-form cleanup degrades in a long-running session

The two full-suite cells above are the finding, not a footnote. **In isolation the
model cleans this input well (0.95, complete); after ~180 prior generations it
cannot do it at all** — 207 words in one arm, a 19× loop in the other — and the
same is true whether or not the input is chunked, so chunking is not the cause.
Something in the shared system-prompt KV cache (`generateCached`'s
prime/trim cycle) degrades with use.

The guard changes make this **fail safe** — the deterministic text ships — rather
than paste a mangled paragraph. They do not fix it. Isolating it means
instrumenting cache offsets across a long run, and it should be done before Smart
cleanup is made on-by-default, because "long dictations quietly never get cleaned"
is the shape it would take in production.

Note also that `long-migration-update` is a **weak detector**: its `must_contain`
keywords are satisfied by the deterministic fallback too, so it scores green
whether cleanup works or not. It is useful for reading outputs by hand; it will not
catch a regression on its own.

## Not verified

- **The R2 install path — cause found, fix needs the live bucket's credentials.**
  The archive was published to the host in the local `.env`
  (`R2_PUBLIC_BASE_URL=https://model.scoopscore.in`), but `.env` is **stale**: commit
  `293fe4c` moved every artifact to `dl.corkkam.com`, which is what
  `ModelInstaller.mirrorBaseURL` compiles in. So the app asks
  `dl.corkkam.com/models/s1-mini-4bit.zip` and gets a **404** — which is exactly why the
  transfer observed here never started. The two are different buckets, not two domains
  on one: the legacy bucket holds `s1-mini-4bit.zip` and `parakeet-tdt-0.6b-v3.zip`, the
  live one holds `Qwen3-4B-Instruct-2507-4bit.zip`. Only the legacy bucket's credentials
  are in `.env`, so the copy cannot be done from this machine.

  **To close it:** copy `models/s1-mini-4bit.zip` from the legacy bucket to the live one
  **byte-for-byte** (do not re-zip — `ditto` embeds timestamps, so identical files
  produce a different hash), then update `R2_PUBLIC_BASE_URL` in `.env`. The SHA-256 of
  the hosted object is already pinned in `ModelChecksums`
  (`517d5091f6c5ac8c8af9a67f1cece60f9cf9899560652e38ba5ca4f788bc17aa`), which it was not
  before — an unpinned archive installs through the safety valve, unverified.

  Until the copy lands, Smart cleanup falls through to the **loud** HuggingFace path and
  fetches `superwhisper/s1-mini` as BF16 (≈1.2 GB) rather than our 4-bit conversion: it
  works, but it is neither the size nor the model these numbers were measured on.
  `EvalRunner` cannot cover any of this — it calls
  `MlxCleanupService.prepare(configuration:directory:)` and bypasses `ModelInstaller`
  entirely, which is why a 404 mirror survived a full eval run.
- **Non-English.** S1-mini is English-only (v1). Parakeet v3 is multilingual. What the
  normalizer does with non-English input is unknown and untested, and the failure would
  be silent. Worth gating before Smart cleanup is ever made on-by-default.

## Recommendation

Adopt. It is better on every axis measured, and the two remaining text failures were
already failing. Before turning Smart cleanup **on by default** — which 335 MB and
100 ms otherwise justify — close the install path and decide the non-English question.
