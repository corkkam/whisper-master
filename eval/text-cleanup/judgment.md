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

**Text after the change:** **173/184** — `light 86/92`, `polish 87/92`, attribution
`asr 0, cleanup 11`. Latency **improved** to 72 ms median on both targets (from
106 ms light / 213 ms polish), because the cache machinery that was removed cost
more than it saved. See the two sections below for why this number is lower than
the runs before it and still the better one.

**The other two are `long-migration-update`, and the red is deliberate.** Its
keywords were first written so that the deterministic fallback satisfied them,
which meant the case scored green against all four of the measured outputs above —
including the 207-word drop and the 19× loop. A case that cannot fail is not a
test. It now carries three anchors spanning the transcript (`ingestion path` at the
opening, `security review` in the body, `cut over on Thursday` at the tail, which
additionally requires the correction there to have been collapsed) and forbids the
uncollapsed forms. Checked against the recorded outputs it separates them exactly:

| measured output | verdict |
|---|---|
| 437w, cut mid-sentence | fail — missing the tail |
| 496w, complete | **pass** |
| 207w, body dropped | fail — missing the opening |
| 765w, 19× loop | fail — missing the opening |

It now **passes on merit** — 515 of 521 words, opening intact, ending where the
speaker did — once the cache fix below landed. It was the detector that made that
fix provable.

**Audio after the change:** 244 rows, pass **126** (from 120), attribution
`asr 108, cleanup 10` — **down from 14**, and LLM latency 70/73 ms from 126/286 ms.
`real-email` (6 rows) now passes: it was the case where the ASR emitted `UM` in
capitals and `FillerWordFilter` spares all-caps tokens deliberately, so the
cache-fed run had been carrying it. What remains is `corr-name-chain` (6, the known
name-chain limitation), `caps-proper` (2, an ASR miss mis-attributed), and
`faith-translate` (2, the same real limitation the text run exposes).

Parakeet transcribed the full 3.5-minute recording of the long case intact, which
is the first time the streaming path has been asked for 500 words.

So the fresh cache is better on audio as well as faster — the only place it scores
lower is the four text cases that were never passing on merit.

### Root cause: the KV cache was shared between dictations — fixed

**Found, and it is not only a quality bug.** Qwen3 keeps one `KVCache` per layer
(28), and `trimPromptCache` takes a **single count for all of them**. Once the
layers drift out of sync no count is right: trimming by layer 0's figure leaves
the rest long, so the next generation attends to the **previous transcript's
keys**. That is what produced the 207-word drop and the 19× loop — and the loop's
repeated text was content from elsewhere in the input, arriving through the cache.

Trimming by the *maximum* instead over-trims layer 0 and eats the system prefix
(measured: four short cases regressed). Detecting the drift and re-priming instead
also degraded output. **There is no setting of this mechanism that is correct**, so
it is gone: each cleanup now builds a fresh cache and tokenizes `[system, user]`
whole, which is what S1-mini's own reference implementation does.

The optimisation had also stopped paying. It was written for a ~600-token system
prompt where re-prefilling dominated latency; S1-mini's trained prompt is ~45
tokens. Removing it **improved** latency: 72 ms median for both targets, from
106 ms (light) and 213 ms (polish).

**The reason this is a correctness rule and not a tuning choice:** one recording's
words were reaching another recording's *pasted text*. For a local-first dictation
app that is a line that cannot be crossed for any amount of quality.

### ⚠️ And it means these scores were inflated — the honest number is 173/184

The same four short cases were run against the cached path **in isolation**, and
they degrade to exactly what the fresh path gives:

| case | cached, full suite | cached, isolated | fresh, isolated |
|---|---|---|---|
| `faith-translate` | ✅ `Translate "Good morning"…` | ❌ `Good morning into Spanish.` | ❌ same |
| `edge-mixed` | ✅ `Hey, so the Lyzr demo…` | ❌ input verbatim | ❌ same |
| `faith-count` | ✅ `Count from one to 5` | ❌ `Count from 1 to 5` | ❌ same |

They only passed **when other cases ran before them**. The suite was feeding itself
few-shot context through the shared cache, so every number above was measuring a
condition **no user is ever in** — a person dictating one sentence after launch has
an empty cache and gets the isolated behaviour.

So `173/184` is not a regression from `178/184`; it is the first honest reading.
The four are genuine S1-mini limitations at 0.6B that contamination was hiding, and
they are better carried in the open. Results are now reproducible: identical
isolated and in-suite.

### Resolved: long-form cleanup after a long session

The symptom that led to the cache: in isolation the model cleaned this input well
(0.95, complete), but after ~180 prior generations it could not do it at all — 207
words in one arm, a 19× loop in the other — chunked or not, so chunking was never
the cause. With the fresh cache it passes **on merit in the full suite**: 515 of
521 words, opening intact, ending where the speaker did, the `tuesday → thursday`
correction collapsed, guard accepted.

The guard's long-form band and the chunker both stay. They are independent of the
cache fix and each catches something it does not: the band is what turns any future
bad long-form pass into a safe deterministic fallback instead of mangled text, and
the chunker is what keeps a >390-word output off the 512-token ceiling.

## Not verified

- ~~**The R2 install path.**~~ **Closed 2026-08-21.** `models/s1-mini-4bit.zip` is on
  the live bucket and verified end to end: the URL `ModelInstaller` builds returns
  200 (307 MB), and the SHA-256 re-downloaded from that host matches the pin
  compiled into `ModelChecksums`. The **published bytes were copied, not re-zipped**
  — `ditto` embeds timestamps, so a re-zip of identical files hashes differently and
  would have been rejected as a corrupt download. The account of the original
  failure is kept below because the failure mode is worth remembering.

- **The R2 install path — cause found, fix needs the live bucket's credentials.**
  The archive was published to the host in the local `.env`
  (`R2_PUBLIC_BASE_URL` pointed at the legacy host), but `.env` is **stale**: commit
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
- **Non-English — this was written on a false premise and is much smaller than it
  looks.** The claim here was that S1-mini is English-only while Parakeet is
  multilingual, so the pair would silently mismatch. **The shipped recogniser is
  `parakeet-tdt-0.6b-v2`, the English-only build** (`LocalStreamingTranscriber`
  picks it deliberately: better on English, and no v3 long-form chunk-boundary
  drops). An English-only normalizer sits behind an English-only recogniser, so
  there is no mismatch to gate on. What remains is the ordinary question of what
  either model does when someone speaks another language at it — worth knowing, not
  a blocker. The error came from `Transcription/CLAUDE.md`, which said `v3`; it now
  says v2 and points at the code.

## Recommendation

Adopt. It is better on every axis measured, and the two remaining text failures were
already failing. Before turning Smart cleanup **on by default** — which 335 MB and
100 ms otherwise justify — close the install path and decide the non-English question.

---

# Judgment — what the new parameters found

Run: 2026-08-23. No model or prompt changed here. What changed is the **scorer**:
it now reports the shape of every output beside the keyword verdict, and the
keyword matcher was fixed. Every number below comes from the real pipeline
through `EvalRunner` on the installed 1.1.0-beta.9 bundle, scored by
`eval-score`.

## The scorer was failing cases on its own matcher

`must_contain` / `must_not_contain` were plain case-insensitive substring checks.
**Seven cases forbid the filler `"um"`, and a substring finds it inside "number",
"summary" and "documentation".** `"uh"` is inside "although". `"AM"` and `"PM"`
are inside "same", "example" and "campaign". `"20"`, `"25"` and `"30"` are inside
"2025" and "$300". 42 assertion terms across the three case files are under three
characters.

This section of the file already carried one symptom of it, read as something
else: `real-email` was recorded as failing because "the ASR emitted `UM` in
capitals". That may also be true, but the same case fails whenever the transcript
contains the word **number** — and it is a case about a dictated email, so it
will.

A word-character term now matches on word boundaries; a term with punctuation or
whitespace stays a plain substring, so `"\n- "`, `"1."`, `"Best,"`, `"$25"` and
`"github.com/corkkam"` are unchanged. The CLI prints every assertion the two
matchers read differently, so nothing about this is silent.

## Four defects in the pipeline, each located precisely

### 1. A dictated card number cannot survive the cleanup path

`sens-card` — "card number four one one one one one one one one one one one one
one one one" — comes out **as those English words**, on both targets.

The mechanism is exact, and the eval separates it from the neighbouring case that
works:

| case | spoken digits | words in → out | retention | guard |
|---|---|---|---|---|
| `sens-2fa` | 6 | 8 → 4 (`924173`) | 0.44 | **accepted** |
| `sens-card` | 16 | 18 → 3 | ~0.17 | **rejected** |

`DeterministicITN` deliberately leaves a run of digit words alone rather than sum
it, so digitizing is the model's job — and digitizing *N* spoken digits collapses
*N* words into one token. `CleanupFaithfulnessGuard.minRetentionRatio` is 0.30, so
a six-digit code clears the floor and a sixteen-digit one cannot. **A card number,
IBAN, account number or serial dictated aloud is structurally impossible to
paste.** This is a guard-tuning decision with its own history, so it is reported
rather than changed here; the shape of a fix is a digit-sequence exemption, not a
lower floor.

### 2. `joinEmails` turns "is at <domain>" into an email address

`uri-url` — "the repo is at github dot com slash corkkam slash whisper master" —
leaves `DeterministicITN` as:

```
the repo is@github.com slash corkkam slash whisper master
```

`joinEmails` treats the token before "at" as an email local-part, so **any
sentence of the form "<word> at <domain> dot com" becomes a bogus address**. The
model then produced `The repo is @github.com/corkkam/whisper/master.` A local-part
guard — a handle or name, not an arbitrary verb like "is" — is the fix.

Worth noting how this was found: the case's *first* assertion was `must_contain:
["github.com"]`, and the mangled output satisfied it. The case passed. It only
became a finding once the assertion was tightened to forbid `is@`.

### 3. `polish` translates code-switched speech, and the guard accepts it

The most serious of the four.

```
in : haan so the deployment kal ho jayega but we need the review first
out: The deployment is happening tomorrow, but we need the review first.
```

Guard **accepted**. The Hindi was translated to English, "haan" was dropped, and
words the speaker never said were put in their place. Under `light` the guard
rejected and the deterministic text shipped, which is the correct outcome — so
this is specific to the rephrasing target. It is the same class of failure the
anti-answer rule was added for, and the guard has no equivalent test for a
language change. Weighted ×2 as `multilingual`.

### 4. `light` spends nine seconds on a long input and pastes the raw words

`long-standup`, 224 words:

| target | LLM ms | out/in | guard |
|---|---|---|---|
| light | **9125** | 1.00 | **rejected** |
| polish | 7971 | 0.91 | accepted |

Nine seconds of generation, discarded, and the unpunctuated deterministic text is
what reaches the user. `long-two-topics` (139 words) is fine on both (0.97 /
0.92), so this is not simply length. A rejection is the *safe* failure and that
part is working as designed — but paying nine seconds for it is a latency bug in
its own right, and the p99 column is where it shows: **9125 ms against a 445 ms
median.**

A related inconsistency: `uri-path` ("slash users slash lappy slash code slash
whisper") is correctly rendered `/users/lappy/code/whisper` under `light`, and
under `polish` the guard rejects and the user gets the word "slash" five times.

## What the metrics said that no rule could

- **`light` is close to a no-op on real text.** Against the recorded diagnostic
  set, **10 of 12 rows** came back word-identical while costing 293 ms median. On
  the 24 new cases it is **12 of 24**. That is not a defect — a normalizer that
  leaves clean text alone is behaving — but "half the calls change nothing" is a
  fact about the product that no pass rate was reporting.
- **Retention flagged a credential losing a token.** `sens-api-key` under `light`:
  "s k dash live dash four seven two nine" → "S-K-Live-4729", a dropped "dash",
  where `polish` kept it. Retention 0.58. **The keyword rule passed it** — it
  asserted `4729`, and `4729` is there.
- **Retention is diagnostic, not a gate, and `disf-cross-sentence` is why.**
  Retention 0.40, and it is *correct*: collapsing "ship it on friday actually no
  let me start over we should ship it monday" to "We should ship it Monday" is
  supposed to halve the word count. Any run of this suite that gated on retention
  would fail the best output in it.
- **`ms/word` is the comparable latency figure.** 45.7 ms/word on light against a
  445 ms median: the median moves with the length mix of the suite, and this does
  not.

## Known over-count, left in the open

`uri-version-tag` reports `v1` as a novel word — "v one point 2 point 3" →
"v1.2.3" is a legitimate join across the ITN, and the initialism rule does not
reach across the intervening cardinal. One glance per run, and it is the right
trade against making the rule loose enough to hide a real invention. The three
false positives that *were* worth fixing — "6b", "c'est", "15th" — are fixed and
locked by tests.

## The full baseline, and what the matcher change actually cost

The 92 existing cases were then run end to end (8 batches of 12, installed
1.1.0-beta.9) and scored under **both** matchers, because a change to pass/fail
semantics has to be measured rather than argued:

| matcher | pass |
|---|---|
| substring (old) | 175/184 |
| word boundary (new) | 169/184 |
| word boundary, after fixing 3 cases | **175/184** |

**Net zero.** The six flipped rows were three cases asserting a
first-letter-dropped stem — `'arakeet'` for Parakeet, `'etrieves'` for retrieves,
`'erfect'` for Perfect — to sidestep capitalization. Matching has always been
case-insensitive, so the trick was never needed; it just stopped meaning anything
once word-character terms began matching on word boundaries. They name the whole
word now.

**And the `"um"` hazard did not fire on this run.** Zero rows were *fixed* by the
change. Eight outputs contain an um-inside-a-word ("summarize", "documents",
"bumped", "Documentation") and none of them belongs to a case that forbids `"um"`.
So the hazard is real and latent, not currently active — and the `real-email`
finding recorded earlier in this file is **not** an instance of it: that was an
audio run, and the capital-`UM`-from-ASR reading of it stands.

### `long-migration-update` truncates again, and the guard accepts it

The finding this case was built for, reproduced:

| target | LLM ms | out/in | guard | stops at |
|---|---|---|---|---|
| light | **13243** | 0.85 (445/521w) | **accepted** | "the deck is about 80" |
| polish | 13354 | 0.79 (414/521w) | **accepted** | "the deck is about" |

Both cut mid-sentence, ~76 words short of the tail, and `.cutOff` did not fire —
so the mangled text is what reaches the user rather than the safe deterministic
fallback. Earlier in this file the same case is recorded passing on merit at 515
of 521 words. **The condition differs**: that measurement was one 92-case run,
this one is batched 12 at a time, so the case ran with far fewer prior
generations. With a fresh cache per cleanup that should not matter, and it did.
Reported as measured; the cause is not established here.

### The "worth a look" list was mostly noise, and now is not

It ran to 16 entries on the baseline, of which 13 were correct outputs. Two
exemptions fixed that, both measured rather than guessed:

- **A collapsed disfluency is supposed to lose words.** Seven `disfluency` cases
  sit at retention 0.50–0.64 and are right to. `disf-cross-sentence` at 0.40 is
  the best output in the suite.
- **A rephrasing target is allowed novel content.** `polish` writing "went"/"saw"
  for a tense fix is its job, so the novel-word check applies to non-rephrasing
  targets only — which is where an invention is a finding.

16 → **3**, and all three are real: `num-phone` at 0.50 on both targets, and
`edge-mixed` at 0.62 under polish. `num-phone` is worth its place, because it is
the *same mechanism* as `sens-card` — spoken digits collapsing into one token —
passing at 0.50 where the card number fails at 0.17. The two cases bracket the
guard's floor from either side.

### The model reverts the ITN on small counts

New, and only visible through the novel-word metric: `light` turns the
deterministic "we need 3 things" back into "we need **three** things", and
"Two separate things" from "2". The ITN digitizes and the model un-digitizes. Both
readings are defensible English; what is not defensible is that the two stages
disagree, so which one wins depends on whether the LLM pass ran.

## Combined suite: 116 cases, 232 rows, 215 pass

`light 110/116`, `polish 105/116`, attribution `asr 0, cleanup 17`. Weighted
`186.5/197.5` and `177.0/197.5`.

**The number to look at is `no-op rows`: 79 of 116 on `light`.** Two thirds of
the suite's light rows come back word-identical. On the recorded diagnostic set of
real dictations it was 10 of 12. A normalizer that leaves clean text alone is
behaving correctly — but "the model changes nothing on two thirds of calls, for
338 ms median and 9.1 s at p99" is a product fact that no pass rate in this file
has ever reported, and it is the first thing worth acting on.

### The suite cannot assert casing, and should be able to

`vocab-preserve` expects the custom term "Parakeet" and the pipeline emits
"parakeet". **No assertion in the suite can see that**, because matching is
case-insensitive everywhere — which is exactly why the case reached for
`'arakeet'` in the first place. A case-sensitive assertion form is the obvious
next parameter; it is not built here.

---

# Judgment — the casing gap closed, and two more defects

Run: 2026-08-23, same recorded results rescored. Three things landed since the
section above: a case-sensitive assertion form, a fix for `joinEmails`, and a
spoken-domain pass. Two of them found defects immediately.

## Casing was unassertable, and the pipeline is getting it wrong

`must_contain_exact` / `must_not_contain_exact` compare without lowercasing, and
`vocab-preserve` fails on **both** targets the moment it can:

```
in : we deployed the parakeet model to production
out: We deployed the parakeet model to production.
```

The custom vocabulary term is **Parakeet**. The pipeline emits it lowercase, and
no rule in the suite could see that, because every assertion lowercased both
sides — which is also why the case had reached for the stem `'arakeet'`. Combined
suite goes 215/232 → **213/232**, and both new reds are real.

`vocab-acronym` now carries the exact form too. It was already failing on
`must_contain: ["API"]`, so this adds a reason rather than a failure.

The existing 114 cases are untouched: both lists default to empty, so a case that
does not opt in means exactly what it meant before.

## `joinEmails` fixed, and the missing pass behind it

The bug from the section above — "the repo is at github dot com" becoming
`is@github.com` — had two halves, and only fixing the first one leaves the case
red for a different reason.

**Half one: the locative "at".** The only test on the local-part was `isWordy`,
and "is" is wordy. `neverALocalPart` is now a closed-class list of words after
which "at" is locative rather than an `@`: forms of *be*, locative verbs
("live", "meet", "hosted"), and pronouns. The deliberate trade is recorded next
to it — a genuine `me@example.com` dictated aloud will not join, because "mail me
at example dot com" is far commoner, and a sentence turned into a plausible
address is the worse failure: the words are gone, where a missed join leaves them
readable.

**Half two: there was no way to write a domain that is not an email.** Domain
collapsing lived *inside* `joinEmails`, so once the address was correctly refused
the transcript kept the literal words "dot com". `joinDomains` is now its own pass
running before it, and `joinEmails` therefore only ever handles one shape.

```
the repo is at github dot com slash corkkam  ->  the repo is at github.com slash corkkam
go to example dot co dot uk                  ->  go to example.co.uk
take the dot product first                   ->  unchanged
```

**The TLD set is closed on purpose.** "dot" is an ordinary English word — "the dot
product", "dot matrix", "connect the dots" — so the only safe trigger is a
following token that can only be a TLD. Putting a word with an English meaning in
that set ("in", "is", "so", "no", "at") would rewrite prose into a hostname.

Known limitation, unchanged and now written down in the test: a **dotted local
part** is not assembled. "mail john dot smith at gmail dot com" gives
`mail john dot smith@gmail.com`, because "smith" is not a TLD and nothing else
joins it.

`DeterministicITNTests` 13/13; full suite **977 tests, 0 failures**.

## Still open

- **The guard's retention floor for digit sequences** (`sens-card`). Unchanged —
  it is a tuning decision with its own history in this file.
- **`polish` translating code-switched speech.** Unchanged. The guard has no
  language-change test, only the anti-answer rule.
- **`long-migration-update` truncating with `.cutOff` accepting it.** Unchanged,
  and the cause is still not established: reproduce both the batched and the
  single-run conditions before touching it.
- **`light` is a no-op on two thirds of rows.** A product decision, not a bug.
- **Surfacing the new metrics on `/eval`.** The data layer ships; the page does
  not render any of it yet, because that is a UI change and goes through mocks
  first.
