# Transcription (`Sources/WhisperMaster/Transcription/`)

Loaded when Claude works under this directory. Moved verbatim out of the root
`CLAUDE.md`, which keeps the one-line prohibitions and a pointer here.

### Transcription engine

`TranscriberEngine` has a **single case**, `slidingWindow` ("Heavy", NVIDIA Parakeet `parakeet-tdt-0.6b-v3`), implemented by `FluidAudioStreamingTranscriber` (conforms to `LocalStreamingTranscriber`, `Sendable`). An earlier "Light"/EOU streaming engine **and** an Apple Foundation Models transcript-cleanup pass were both removed — the LLM added latency without gains since Parakeet already emits punctuation/capitalization. The enum is kept (one case) for metadata + future engines. `PrototypeViewModel.transcriber` is now a single stored property.

**One track, and no live preview of it.** `SlidingWindowAsrManager` only decodes once it holds `chunkSeconds + rightContextSeconds` of audio, so at the shipped `.streaming` config (11 s + 2 s) it emits **nothing for the first 13 seconds** — longer than a typical dictation, so on a short one the notch shows no words at all and the whole transcript lands at once from `finish()`/`flushRemaining()` when the key comes up. That is the accepted behaviour. (`SlidingWindowAsrConfig.hypothesisChunkSeconds` advertises "quick hypothesis updates for immediate feedback" but **nothing in FluidAudio ever reads it** — there is no hypothesis track to enable.)
- **The short-window "preview" track was removed on purpose — do not bring it back.** A second `SlidingWindowAsrManager` (1.5 s chunk, `confirmationThreshold: 0`) used to run off the same mic buffers purely to paint the notch while you were still speaking, carried on `StreamingTranscriptUpdate.isPreview` and displayed through `previewTranscript` / `TranscriptMerger.tidiedPreview`. The live text was not wanted, and it cost an extra encoder pass per window for the length of every recording. All of it — the second manager, the `isPreview` flag, `tidiedPreview`, and the replay test that locked the split in — is gone.
- **Do not "add live text" by lowering `chunkSeconds` either.** `finish()` reconstructs the final transcript from those same windows, so shorter windows mean less acoustic context and a worse transcript — the one thing that actually gets pasted. Models download on demand into `~/Library/Application Support/FluidAudio/Models/<cacheDirectoryName>`; `TranscriberEngine.isInstalled` is a filesystem check, so callers must not cache it. (The removed cleanup pass above was the *Apple Foundation Models* one; a separate **opt-in MLX qwen cleanup** was later added — see below.)

### On-device Smart cleanup (MLX — opt-in, off by default)

**Two models, because these are two jobs.** Cleanup runs **S1-mini by Superwhisper**
(`MlxCleanupService.shared`) — a 0.6B text normalizer fine-tuned from Qwen3-0.6B,
converted here to 4-bit: 335 MB on disk, ~100 ms. Tool calling and intent run
**Qwen3-4B-Instruct-2507** (`CleanupModel.General`, `MlxCleanupService.general`),
whose 2507 instruct build carries a real function-calling posture and is non-thinking
by default so it never emits `<think>` blocks that break the loop's JSON parse.

Measured end to end through the app on `eval/text-cleanup/cases.jsonl` with the guard
applied: the outgoing qwen2.5-3B scored **85/89 at ~250 ms on 1.5 GB**, S1-mini scores
**87/89 at ~100 ms on 335 MB**. Audio and LibriSpeech runs found no cleanup regression;
see `eval/text-cleanup/judgment.md`.

**⚠️ Never point the agent or the intent classifier at the cleanup slot.** S1-mini is
not a chat model and will not follow general instructions — handed a tool schema it
returns normalised prose, no call parses, `CommandAgentService` correctly reads that as
"did not act", and the whole assistant degrades to the keyword gate **with no error to
show for it**. Both `AgentLoop.liveGenerator()` and `liveNativeGenerator()` go through
`prepareGeneralIfInstalled()`, which loads the general model **only when it is already
on disk and never downloads it**.

**The assistant model has its own install, with two triggers and neither is launch**
(`AssistantModelManager`). Splitting the models split the *download* too: Smart cleanup
now fetches a 335 MB normalizer, so without this nothing ever fetched the 2 GB
tool-caller and every install silently ran the assistant on the keyword gate. It is
fetched on the **first use of the chord** (the `connectorAgentEnabled` toggle is the
permission; the capture in flight is never made to wait on it and still takes the
deterministic path) or from the **Settings button**. `AssistantModelManager.Policy` is
pure so the rule is tested without a 2 GB download; one fetch per launch, and a failure
is retried only from Settings, never from the next spoken command.

**⚠️ `assistantModelReady` is not `cleanupModelReady`.** The Settings hint used to read
the latter, which was right only while the two jobs shared one model — after the split
it cleared the "not on this Mac" warning the moment S1-mini loaded and claimed a model
that had never been downloaded. `AssistantModelTests` locks the separation.

**⚠️ A long dictation is cleaned in pieces, and the guard is not the safety net
here** (`TranscriptChunker`). `MlxCleanupService` caps a generation at 512 tokens
against a runaway decode; at ~1.3 English tokens per word that is ~390 words of
output, past which the pass was cut mid-sentence. `CleanupFaithfulnessGuard` did
**not** catch it — its truncation floor is 30% retention (anything tighter rejects
legitimate self-corrections), and a 500-word dictation truncated to 390 retains 78%.
On the native path that accepted truncation then *replaced* text the user had
already watched land. The chunk budget is **240 words** because that is exactly the
largest input for which the service's `words * 2 + 32` token budget stays inside
512 — the two constants are pinned to each other by a test, so moving either one
fails loudly. Chunking is skipped for the `email` context, whose greeting/sign-off
layout spans the whole text. A chunk that fails keeps its own raw words.

**S1-mini's format is exact and every integration bug traces to it**: the system prompt
is the trained string (not a prompt to tune), the user turn opens with a
`[Styling: …] [Structure: …] [Context: …]` control line, and **`enable_thinking` must be
false**. The name is a **licence term** — Apache 2.0 plus one condition, that it keeps
the name "S1-mini by Superwhisper" with that capitalization. "Polish my English" became
**"Formal styling"**, because S1-mini normalises and will not restructure a sentence.

The older description of the single-model design follows.

Optional post-ASR cleanup by **qwen2.5-3B-Instruct-4bit via MLX** (`mlx-swift-examples`). Two Settings toggles: **Smart cleanup** (`llmCleanupEnabled` — light: fix self-corrections/false starts) and **Polish my English** (`llmGrammarPolishEnabled` — heavier rephrase to grammatical English). Dictation **never waits** on it: the deterministic text pastes instantly and, on the **native** path, the qwen polish refines it *in place* a beat later (`scheduleRefinement`); on the **web/Electron** path (no safe in-place edit) polish is computed *before* the ⌘V. Pieces:
- **`MlxCleanupService`** (`actor`) — loads the model once and reuses a persistent system-prompt **KV cache** (feeds only the per-call delta). `clean()` returns `nil` on any problem so the caller keeps the deterministic text — cleanup can only ever help, never block. The load is **timeout-bounded (`loadTimeoutSeconds` 60 s) and retried** by the manager: a stalled MLX/Metal init (seen under launch-time GPU contention) used to wedge the state `.loading` forever, so Settings showed "Preparing…" indefinitely while polish silently no-op'd. Load/prime timing is logged.
- **`CleanupModelManager`** (`@MainActor`, owned by `DictationViewModel`) — reconciles the toggle each refresh tick, drives the **mirror-first background download** (`ModelInstaller`, R2 archive `Qwen2.5-3B-Instruct-4bit`, HF fallback), retries the load up to 3×, and surfaces status to `AppState`: `cleanupModelReady` / `cleanupModelFailed` (→ Settings shows **"Couldn't load — Retry"**, `cleanupRetryRequested` re-attempts) / `cleanupModelReadyAt` (one notch banner). Progress shows **only in Settings**.
- **`CleanupTarget`** names every cleanup/format mode the eval can grade. `light` and `polish` are the shipped Settings toggles (`CleanupPrompt.system` / `.grammarPolish`). `slack`, `email`, and `code` are **eval-only destinations** (à la Wispr Flow) — they exist so we can measure app-aware formatting without wiring those prompts into the paste path. Do not call them from `DictationViewModel`. Adding a target is a case on the enum + a prompt + cases that list it; `EvalRunner` iterates `CleanupTarget.allCases`.
- **`CleanupFaithfulnessGuard`** (pure, `CleanupFaithfulnessGuardTests`) — rejects the LLM output (→ keep deterministic) when it **invents** content (answers/translates/codes/injects), balloons, or grossly truncates; `allowRephrase` loosens it for polish mode (and for the eval-only format targets). **Known limitation, do not "fix":** it catches *added* content but not a *dropped* content word ("meant to be born" → "meant to be"). A deterministic word-counter can't tell that from a legitimate self-correction ("john i mean jane" → "Jane") or compression ("gonna go" → "going") — a content-retention rule was tried and **reverted** because it rejected those. So polish occasionally drops a word; that's why "Polish my English" is **experimental/off-by-default**. Verify any cleanup change against the real pipeline via `eval/text-cleanup/run-eval.sh` (it grades the shipped passes + both LLM modes + the real guard).

**Model install is mirror-first.** `ModelInstaller` (in `ModelInstall/`, with `BackgroundFileDownloader` + `DownloadResumeStore` + `Archive`) is archive-based — `installIfNeeded(archiveName:destinationRoot:label:maxAttempts:isInstalled:onProgress:)` downloads `<archiveName>.zip` from the public R2 bucket and unpacks it into `destinationRoot`, with an accurate % (R2 returns a real `Content-Length`). It **retries** the download+unpack (`maxAttempts`, default 2). The download is **resumable**: `BackgroundFileDownloader` uses a **background `URLSession`** (owned by `nsurlsessiond`, keyed by a fixed identifier) writing to a *stable* path `<destinationRoot>/.downloads/<archiveName>.zip`, so an interrupted 1.5 GB transfer resumes instead of restarting from zero — it reattaches to a transfer the daemon kept running across an app quit, else resumes from persisted `NSURLSessionDownloadTaskResumeData`, else starts fresh. `DownloadResumeStore` persists the URL→destination map (so a transfer the daemon finishes while the app is quit is moved into place on the next launch) and the resume token, both under `.downloads/`; `AppDelegate` touches `BackgroundFileDownloader.shared` at launch so replayed completion events drain before any new download decision. Timeouts are **bounded** (120 s stall / 24 h resource, not the 7-day URLSession default). Only after retries are exhausted does it fall back to FluidAudio's HuggingFace download — and that fallback is **loud, not silent**: logged at `.error` via `Log.modelPrep` (subsystem `app.whispermaster.mac`, persisted to the unified log) and surfaced in the UI (`AppState.usingFallbackModelSource` → "downloading from backup source (slower)"). Note `TranscriberEngine.isInstalled` validates the **actual compiled files** (each required `.mlmodelc`'s `coremldata.bin`), not just that the folder exists — a half-deleted/partial install correctly re-fetches from the mirror instead of masquerading as ready (which used to drop it to the slow HF path). This whole chain was the cause of the intermittent "model loading stuck" bug: a bare-folder `isInstalled` + silent HF fallback + no download timeout. A `TranscriberEngine` convenience overload covers the main engine (`DictationViewModel.installModelsFromMirror`, before `prepareModels`); the CTC vocabulary model uses the generic form. **Both the engine model and the CTC model are hosted on R2.** To publish/refresh an archive: from the models root (`~/Library/Application Support/FluidAudio/Models`), `ditto -c -k --keepParent <dir> <dir>.zip`, then upload to `whisper-master/models/` on R2 (same creds as `release.sh`). **After uploading, pin the archive's SHA-256** — `shasum -a 256 <dir>.zip`, then add/update `<archiveName>` → that hex in `ModelInstall/ModelChecksums.swift`. The R2 archives are **not** Sparkle-signed the way the app bundle is, so `ModelInstaller` verifies each downloaded zip against this compiled-in pin (streamed via CryptoKit `SHA256`, no full read into memory) **before** unpacking: a mismatch is treated as a failed download (the bad zip is deleted, never unzipped) and falls through to the loud HuggingFace fallback, and an archive with **no** pin installs but is logged as unverified. Skip the pin and a new archive ships unverified — so update `ModelChecksums` in the same change as the upload.

**Custom vocabulary (biasing).** Users maintain a glossary — `PrototypeAppState.customVocabulary` (persisted under `WhisperMaster.customVocabulary.v1`), edited in the Voice-engine **"Words to get right"** field (a raw `@State` draft parsed one-way to `[String]`; don't reintroduce a normalizing two-way binding or Enter/multiline breaks). `FluidAudioStreamingTranscriber.setVocabulary` stores terms (cheap); `loadVocabularyResources` loads FluidAudio's CTC keyword model (R2-first, ~89 MB, guarded against duplicate loads) in the **background** and calls `configureVocabularyBoosting`, biasing decoding toward those terms (e.g. "RAG" not "rack"). It's warmed right after the main engine is ready (`refreshCustomVocabulary`) and re-applied after each session's manager recreation in `stop()`/`cancel()`, so it never blocks recording and is best-effort. Biasing is CTC acoustic rescoring with thresholds — short acronyms are the hard case; tune via `CustomVocabularyTerm` weight/aliases if needed.

**Custom vocabulary is post-processing, not engine biasing.** FluidAudio's
streaming CTC vocabulary rescorer corrupts transcripts (empties vocab-dense
utterances, truncates others — proven by `AudioReplayTests`), so it is **not
used**. `VocabularyPostProcessor` applies the glossary as a safe whole-word
text replacement on the finished transcript instead. Do not re-enable
`configureVocabularyBoosting` to "improve accuracy" — it regresses correctness.

**Deterministic ITN, and why it must not sum digit sequences.** The finished
transcript runs through `DeterministicTextFormatter` → `DeterministicITN.normalize`
(the default `TextFormatting`; the Apple on-device LLM formatter is opt-in only).
This is a pure, rule-based inverse-text-normalization engine — spoken numbers →
digits, currency, %, times, emails — written in Swift (no model, instant,
deterministic). `SpokenNumber.value` combines number words **additively**, which
is only valid for a tens word (20–90) + a ones word (1–9) ("twenty five" → 25) or
across a scale word ("one hundred twenty three" → 123). A run of bare unit words
like "one two three" is a spoken *sequence*, not a cardinal, so it must return
`nil` and stay as words — **do not** let it fall through to the additive sum,
which produced the "mic testing one two three" → "mic testing 6" bug (1+2+3).
When a run isn't a well-formed cardinal, `convertNumbers` emits the *whole* run as
words rather than digitizing a trailing token. **Room/suite numbers** spoken as
digit-chunks ("room two oh five" → "room 205", "room two fourteen" → 214) are
read by a room-keyword-gated pass (`matchRoomNumber`) as a concatenated digit
sequence, **not** a clock time — without the gate `matchTime` greedily turned
them into "2:05"/"2:14". Cover any ITN change with
`DeterministicITNTests` (fast, pure). A heavier long-term alternative — swapping
this hand-rolled engine for FluidInference's `text-processing-rs` (a Rust/NeMo
ITN port with Swift xcframework bindings, same vendor as FluidAudio) — was
evaluated but not adopted: it adds a native binary + build/signing complexity for
coverage we don't yet need.

**Spoken number self-corrections collapse deterministically, before ITN.**
`SelfCorrectionCollapser` (pure, `SelfCorrectionCollapserTests`) rewrites
"twenty five no forty dollars" → "forty dollars", "three no four thirty" →
"four thirty", and chains "twenty no thirty no forty units" → "forty units"
(keep-last). It fires **only** when a number run flanks a correction on both
sides, so ordinary "no"/"actually" in running speech is never touched.
**The correction is matched as a *run* of markers and fillers, not one fixed
phrase** (`correctionRunLen`): people stack them and stumble mid-correction, so
"twenty no no thirty no no forty" and "three uh no wait four" collapse exactly
like the single-marker form. Matching one marker only was the bug behind
"20 no no 30 no no 40" — the collapse missed, and ITN then digitised every value
in the stack. The run must carry at least one real marker (`no` / `nope` /
`actually` / `sorry` / `rather` / `no wait` / `no actually` / `i mean` /
`i meant` / `make that` / `scratch that` / `or rather`); fillers alone are not a
correction, so "one um two" keeps both numbers. It runs in the shipped pipeline (`DictationViewModel`, right after
`TranscriptSpacingRepair`, before `DeterministicITN`) **and** the eval runner, in
the same order — keep them in sync. Name-correction chains ("call john no jane no
actually mike") can't be number-gated safely, so they stay with the LLM (a chain
example in `CleanupPrompt`); a 3B model still misses some — a known limitation.
