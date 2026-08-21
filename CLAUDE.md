# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A standalone macOS menu-bar app prototype for local-first streaming dictation, built on `FluidAudio` + NVIDIA Parakeet. This is the sandbox for evaluating on-device streaming ASR on Apple Silicon.

## Commands

This is an **Xcode project**, generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is the source of truth; the `.xcodeproj` is git-ignored and regenerated. `Package.swift` is kept so `swift build` still works for quick CLI compile checks, but the shippable `.app` is produced by Xcode.

```bash
# First time / after editing project.yml or adding source files
brew install xcodegen        # one-time
xcodegen generate            # (re)creates WhisperMaster.xcodeproj
open WhisperMaster.xcodeproj # work in Xcode normally

# Quick compile check (no .app bundle)
swift build

# Run the test suite (pure unit tests — fast, no models, no audio)
swift test

# Replay recorded audio through the real streaming pipeline (regression bench)
swift test --filter AudioReplayTests

# Build + sign the distributable .app (xcodegen → xcodebuild → stage)
bash Scripts/bundle.sh                       # → build/Whisper Master.app (Release, signed "whisper master")
CONFIG=Debug bash Scripts/bundle.sh          # debug-config variant
SIGN_IDENTITY=- bash Scripts/bundle.sh       # ad-hoc instead of the keychain cert

# DMG (chains through bundle.sh)
bash Scripts/make-dmg.sh                # full rebuild + DMG
REBUILD=0 bash Scripts/make-dmg.sh      # repackage existing .app only

# One-shot install: build → quit running instance → replace /Applications/Whisper Master.app → relaunch
bash Scripts/install.sh
REBUILD=0 bash Scripts/install.sh       # skip rebuild
RELAUNCH=0 bash Scripts/install.sh      # install without launching

# Ship a Sparkle auto-update — bump CFBundleShortVersionString AND
# CFBundleVersion in Resources/Info.plist first, then:
bash Scripts/release.sh                 # build → sign → appcast → upload to R2
REBUILD=0 bash Scripts/release.sh       # re-upload without rebuilding
```

### Tests

`Tests/WhisperMasterTests/` (SwiftPM test target, declared in `Package.swift`
only — the Xcode app target is untouched). Run with `swift test`.

- **Pure unit tests** — fast, deterministic, no models/network/audio. Cover the
  text-processing pipeline: `FillerWordFilter`, `VocabularyTermParser`,
  `VocabularyPostProcessor`, `CorrectionDetector`, `TranscriptMerger.bestEffort`.
  These run everywhere (CI, fresh clone) and should stay green.
- **`AudioReplayTests`** — a regression *bench*, not a pure unit test. It replays
  real recordings through the actual `FluidAudioStreamingTranscriber` streaming
  path (feeding a file reproduces live streaming exactly — windowing keys off
  absolute sample position) and writes results to `.context/test-audio/results.md`
  (git-ignored scratch). The reference recordings live in
  `Tests/WhisperMasterTests/Fixtures/audio/` (committed: `paragraph-N.m4a` +
  `paragraphs.md`, ~1.2 MB), so the bench runs in any clone / CI. The harness
  **also** scans `.context/test-audio/` so you can drop ad-hoc local recordings
  there without committing them (same-named file: the committed fixture wins). It
  **skips** (never fails) when no recordings are found. Run with
  `swift test --filter AudioReplayTests`. This bench is how the FluidAudio
  streaming-vocabulary corruption bug was found and verified — use it to validate
  any change to the transcription/post-processing pipeline before shipping.

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
(keep-last). It fires **only** when a number run flanks a correction marker
(`no` / `no wait` / `no actually` / `actually` / `i mean` / `scratch that` /
`or rather`) on both sides, so ordinary "no"/"actually" in running speech is
never touched. It runs in the shipped pipeline (`DictationViewModel`, right after
`TranscriptSpacingRepair`, before `DeterministicITN`) **and** the eval runner, in
the same order — keep them in sync. Name-correction chains ("call john no jane no
actually mike") can't be number-gated safely, so they stay with the LLM (a chain
example in `CleanupPrompt`); a 3B model still misses some — a known limitation.

### Evaluation engine (`eval/text-cleanup/`)

A quality-first eval for the cleanup pipeline: durable logic in Swift, disposable
glue in shell, Claude Code as the judge, with run history on a public dashboard.
Full details: **`.claude/skills/eval-pipeline/SKILL.md`**. Verify any change to the
cleanup pipeline against the real thing via `eval/text-cleanup/run-eval.sh`.

### Toolchain & prerequisites

- **Apple Silicon, macOS 14+.** Build is **arm64-only**; deployment target macOS 14.0. Developed on macOS 26 / **Xcode 26.5**; Swift language mode **5.0** (`SWIFT_VERSION` in `project.yml`).
- **Full Xcode is required** (not just Command Line Tools — the macro plugins / app target need it). Point the toolchain at it and verify:
  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  xcodebuild -version              # must show Xcode, not CommandLineTools
  sudo xcodebuild -license accept
  ```
- **CLI tools (Homebrew):** `brew install xcodegen rclone` — XcodeGen generates the project; rclone uploads to R2.

### Dependencies (SPM)

Declared in **both** `project.yml` (source of truth for the app target) and `Package.swift` (so `swift build` + the editor resolve) — keep the two in sync when adding/bumping:
- **FluidAudio** ≥ 0.14.7 — on-device ASR (NVIDIA Parakeet) + the CTC keyword model used for vocabulary biasing.
- **Sparkle** ≥ 2.6 (resolves 2.9.x) — auto-update. Xcode embeds/signs the framework automatically; replicating that by hand is the main reason the project moved off the old SwiftPM-only bundle onto an Xcode app target.
- **PostHog** (`posthog-ios`) ≥ 3.0 — opt-in, account-linked product analytics (see **Analytics** below). Replaced TelemetryDeck (free-tier too limited).
- **mlx-swift-examples** (`MLXLLM`/`MLXLMCommon`) pinned exact 2.29.1 — on-device qwen cleanup (the `ChatSession`/`MLXLMCommon` API churns between minors).
- **Clerk** (`clerk-ios`) ≥ 1.3.0 — auth for the launch sign-in gate (see Authentication below). Two products: `ClerkKit` (core + observable state) and `ClerkKitUI` (prebuilt `AuthView`). Pulls transitive deps (PhoneNumberKit, Nuke, swift-collections). Native macOS 14+ support, so no Catalyst shim.

### Release safety rules (mechanics live in the `releasing` skill)

Full workflow: **`.claude/skills/releasing/SKILL.md`** — read it before cutting a
release. These prohibitions stay here because they must hold even when that skill
is not loaded:

- **⚠️ Never republish a version number.** Each release needs a *new*
  `CFBundleShortVersionString` — the archive is `WhisperMaster-<version>.zip`, so
  re-shipping a version overwrites those bytes while the appcast's
  `sparkle:edSignature` is computed for the new ones, and Sparkle fails with "The
  update is improperly signed and could not be validated." This bites silently
  after a `git revert` (code changes, version doesn't). Fix by bumping to a fresh
  version, never by re-uploading the broken one.
- **Bump both** `CFBundleShortVersionString` **and** `CFBundleVersion` in
  `Resources/Info.plist` before a manual release, or Sparkle won't see it as newer.
- **⚠️ The public R2 host is baked into shipped bundles in three places** —
  `Scripts/channel.sh` (`CH_SU_FEED_URL`), `Auth/BetaAccess.swift`
  (`UpdateChannel.feedURLString`), `ModelInstall/ModelInstaller.swift`
  (`mirrorBaseURL`) — plus `R2_PUBLIC_BASE_URL` in `.env`. Change hosts only by
  editing all four together **and** copying `models/` to the new bucket first; an
  empty `models/` prefix silently degrades every user to the slow HuggingFace path.
- **Never commit directly to `main`** — it only receives merges from `release/*`
  and `hotfix/*`, and every production release is tagged `vX.Y.Z`.
- **Non-stable channels must carry the channel marker in the version** (`-beta.N`,
  `-dev.N`); `release.sh` aborts otherwise, which is what stops a beta/dev upload
  from colliding with a stable archive.
- **`[skip release]`, `[skip announce]`, and `[skip ci]` are three different
  switches** — whole release job, Telegram step only, and the entire workflow
  (GitHub-native) respectively. Don't confuse them.

## Architecture

### Process / window model

- **Regular Dock app** — `LSUIElement = false` (Info.plist) + `setActivationPolicy(.regular)` (AppMain) → shows a Dock icon and an app menu (`AppDelegate.setupMainMenu`). The menu-bar `NSStatusItem` is still the primary surface, but macOS hides it when the menu bar is crowded (notch), so the Dock icon is the reliable way back in. (Was previously an `.accessory`/`LSUIElement=true` agent with no Dock icon.)
- `AppDelegate` is the single owner of all top-level objects: the status item, settings window, dictation pill window, hotkey manager, permissions manager, and a dedicated `MicrophoneCaptureService` instance for the onboarding mic test (separate from the one inside `PrototypeViewModel`, since both create their own `AVAudioEngine`).
- `applicationShouldTerminateAfterLastWindowClosed → false`: closing the settings window must NOT quit the app — the tray is the persistent surface. The `NSStatusItem` uses `autosaveName` so users can drag its position and it sticks across launches.
- A 0.5s `Timer` in `AppDelegate.startStatusRefreshLoop` polls `PrototypeAppState` and rebuilds the tray icon symbol, tooltip, header line, and history submenu. There's no `@Observable` bridge to AppKit — the timer is the bridge. **Every AppKit write on this path is change-guarded** (`appliedTrayIconKey` / `appliedTrayTooltip` / `appliedTrayHeader`, `renderedHistoryIDs`, and the `ignoresMouseEvents` check inside `DictationPillWindow.setInteractive`): the answer is identical on nearly every tick, and writing anyway meant allocating a fresh `NSImage` and pushing a status-item update through the menu-bar server twice a second for the life of the process. Keep new per-tick writes guarded the same way — an unguarded `button.image = …` here is a permanent background cost, not a one-off.

### Authentication — Clerk sign-in gate (`Auth/`)

The app is **gated behind Clerk sign-in at launch**: dictation won't start until a user is authenticated. This is a deliberate choice layered on top of the otherwise local-first design — transcription itself still runs entirely on-device; only the *gate* talks to Clerk's cloud.

- **Config (`Auth/ClerkConfig.swift`).** The publishable key is client-safe, read from `Info.plist` `ClerkPublishableKey` (env `CLERK_PUBLISHABLE_KEY` overrides for dev). **You must set a real `pk_test_…`/`pk_live_…` key** or the app stays locked with an "add your key" message — a missing/placeholder key is treated as unconfigured and we never call `Clerk.configure` with it (its validation `assertionFailure`s in debug). `configureIfPossible()` runs first thing in `applicationDidFinishLaunching`, before anything reads `Clerk.shared`.
- **Gate window (`Auth/AuthGateWindow.swift` + `AuthGateView.swift`).** A close-button-less `NSWindow` hosting SwiftUI `AuthView(isDismissible: false)` from `ClerkKitUI`, injected with `.environment(Clerk.shared)`. A plain centered `NSWindow` with Daylight chrome (it predates the move of onboarding into the notch, and stays a window — the sign-in gate has to be unmissable and unskippable). Shows a spinner while Clerk restores a persisted session; the setup message when unconfigured. Cmd-Q still quits (you can leave, not bypass). `AuthGateView` shows **only `BrandLogo` above the card** — Clerk's `AuthView` renders its own "Continue to Whisper Master" / "Welcome!" header that has no public hide toggle, so a custom wordmark+tagline on top duplicated it.
- **OAuth social sign-in needs each build's redirect URL allowlisted in the Clerk dashboard (server-side, not code).** Clerk's iOS/macOS SDK does social OAuth (Apple/Google/X) via `ASWebAuthenticationSession` with redirect `{bundleIdentifier}://callback` (the SDK default; we pass no `redirectConfig` override). Clerk's API **rejects the request** with *"The current redirect url … does not match an authorized redirect URI for this instance"* unless that exact URL is on the instance's allowlist. Because the instance is keyed on bundle id (above), the three builds need three different URLs across the **two** instances — add each in **Clerk Dashboard → Configure → Native applications → "Allowlist for mobile SSO redirect"** (or via the Backend API `POST /v1/redirect_urls` with that instance's `sk_…` key), in the **matching instance**: `app.whispermaster.mac://callback` **and** `app.whispermaster.mac.beta://callback` on the **live** instance (`whisper.corkkam.com`); `app.whispermaster.mac.dev://callback` on the **dev** instance (`sweeping-humpback-68`). This is **not** the "Restrictions → Allowlist" page (that gates sign-*ups* by identifier, a different Pro feature). Email OTP works without any of this — only the OAuth buttons use the redirect. No rebuild needed; it takes effect on the next sign-in.
- **Bridging (the same 0.5s timer).** `Clerk` is `@Observable`; `AppDelegate.reconcileAuthGate()` — called from `refreshStatusItem()` each tick — reads `Clerk.shared.user`/`isLoaded` and shows/hides the gate. `presentAuthGate()` is idempotent (won't re-steal focus). On first sign-in, `proceedAfterAuthIfNeeded()` runs the deferred launch bring-up **once**: the LAN transcription server, the mesh, onboarding, and the settings window. **These deliberately don't start at launch anymore** — they're held behind the gate. Signing out (tray **Sign Out** → `Clerk.shared.auth.signOut()`) re-shows the gate but doesn't tear them back down.
- **Enforcement points.** Both dictation entry points guard on `isSignedIn` (`ClerkConfig.isConfigured && Clerk.shared.user != nil`): the hotkey handler in `setupHotkey` and the tray `startRecording` — a press while signed out surfaces the gate instead. `DictationViewModel` stays Clerk-free; all auth lives in the App layer.

### State (`PrototypeAppState`)

Single `@Observable` source of truth, `@MainActor`-bound. The view model mutates it; SwiftUI views observe it; AppDelegate's tray refresher polls it. Includes:

- `phase: PrototypePhase` (idle/preparingModels/recording/stopping/failed)
- Engine selection state — `selectedEngine`, `preparedEngine`, `preparingEngine` are three distinct slots (do not collapse them; the UI distinguishes "user has chosen X" from "X is currently being downloaded" from "X is ready to use").
- `history: [TranscriptHistoryEntry]` — persisted in `UserDefaults` under `WhisperMaster.transcriptHistory.v1`, capped at 50 entries (newest first). `appendHistory` is the only entry point; bypassing it skips persistence.

### Usage & Insights (`Usage/`, `InsightsSettingsView`)

The Insights settings tab is a **real analytics dashboard, not mock data** — WPM gauge, fixes tally, lifetime words, per-app usage bars, and a GitHub-style streak heatmap, all computed live from recorded dictations. `UsageStore` (`@MainActor @Observable`) is the source of truth; `DictationViewModel` calls `usageStore.record(DictationRecord(...))` at each stop with the real word count, session duration, fix counts, and the **frontmost app** (name + bundle id — the app about to receive the paste, same snapshot the diagnostics use). It keeps append-only per-day `DailyRollup`s (never trimmed — they back lifetime totals + streaks past the 50-entry history buffer) plus a bounded ring of recent records for the rolling WPM window, persisted as JSON. The **only** mock seeding is `SnapshotMode.seedUsage`, which runs *exclusively* in the headless `WM_SNAPSHOT` PNG renderer and sets `persistenceEnabled = false` so it never touches a real file.

**Usage is per-account, not device-wide.** Because the org flow lets multiple people sign into one Mac (Clerk gate), each account gets its own file at `Application Support/WhisperMaster/Usage/<userId>.json`. `AppState.usageStore` starts empty (`UsageStore(load: false)`); `AppDelegate.reconcileAuthGate()` calls `usageStore.activate(userID:)` when a Clerk user is present (idempotent — reloads only on a change) and `deactivate()` on sign-out, so the dashboard only ever shows the signed-in user's numbers. The **same instance is repointed** (file swap + reload), never replaced, so `UsageSyncClient`'s and the views' references stay valid. Each account **starts fresh** — the pre-per-user device-wide `usage.json` is deliberately *not* migrated in (a snapshot-renderer bug could once seed it with mock Slack/Safari/Xcode data; adopting it would carry that in), so it's left untouched on disk and ignored.

**Cloud sync (`UsageSyncClient` → dashboard `POST /api/usage`).** Best-effort, debounced, single-flight background push of *dirty* days only, attributed to the signed-in account via `AppDelegate.currentUsageIdentity()` (Clerk user id + fresh session token). Local is always the source of truth; sync is opt-out (`usageSyncEnabled`, on by default). The dashboard stores `usageDaily` keyed `userId_day` and reads are public (`GET /api/usage/<userId>`). **Server-side per-user attribution is cryptographically enforceable:** `api/usage/+server.ts` verifies the Clerk session token via `@clerk/backend`'s `verifyToken` and derives the trusted `userId` from the JWT `sub` claim (ignoring `body.userId`) **whenever `CLERK_SECRET_KEY` or `CLERK_JWT_KEY` is set** — in that mode an unverifiable/absent Bearer token is rejected (401) and the shared-token path is disabled, so writes can't be spoofed. With neither env set it falls back to the shared `x-ingest-token` MVP mode (trusts `body.userId`, spoofable) — fine for the internal deploy. **To lock down multi-tenant writes, just set `CLERK_SECRET_KEY` (optionally `CLERK_JWT_KEY` for networkless JWKS + `CLERK_AUTHORIZED_PARTIES` to pin `azp`) in the Vercel + local env** (see `.env.example`); no code change needed. The macOS app already sends the token — `AppDelegate.currentUsageIdentity()` attaches a fresh `Clerk.shared.session.getToken()` as `Authorization: Bearer`.

### Transcription engine

`TranscriberEngine` has a **single case**, `slidingWindow` ("Heavy", NVIDIA Parakeet `parakeet-tdt-0.6b-v3`), implemented by `FluidAudioStreamingTranscriber` (conforms to `LocalStreamingTranscriber`, `Sendable`). An earlier "Light"/EOU streaming engine **and** an Apple Foundation Models transcript-cleanup pass were both removed — the LLM added latency without gains since Parakeet already emits punctuation/capitalization. The enum is kept (one case) for metadata + future engines. `PrototypeViewModel.transcriber` is now a single stored property.

**Two tracks, one engine — the notch's live text is the `isPreview` track.** `SlidingWindowAsrManager` only decodes once it holds `chunkSeconds + rightContextSeconds` of audio, so at the shipped `.streaming` config (11 s + 2 s) it emits **nothing for the first 13 seconds** — longer than a typical dictation, so the notch stayed empty until the key came up and the whole transcript landed at once from `finish()`/`flushRemaining()`. (`SlidingWindowAsrConfig.hypothesisChunkSeconds` advertises "quick hypothesis updates for immediate feedback" but **nothing in FluidAudio ever reads it** — there is no hypothesis track to enable.) So `FluidAudioStreamingTranscriber` runs a **second `SlidingWindowAsrManager`** with a short window (`previewStreamingConfig`: 1.5 s chunk, 0.3 s right context, `confirmationThreshold: 0` so every window promotes and the text accumulates) fed the same mic buffers — first words at ~1.8 s. Both managers share the one loaded `AsrModels` (`AsrManager.loadModels` only retains `MLModel` references), so there's no extra download, load, or memory; the cost is extra encoder passes while recording. `startStreaming(source:)` does **not** touch the microphone — it only labels the source and consumes what `streamAudio` feeds — which is what makes two tracks off one capture session safe.
- **Preview output is display-only.** Updates carry `StreamingTranscriptUpdate.isPreview`; `DictationViewModel` puts them in `previewTranscript` and **never** into `rawConfirmedTranscript`/`rawVolatileTranscript`, so preview text cannot reach the paste, history, salvage, or cleanup passes. `refreshLiveTranscriptDisplay()` shows the preview (all in volatile ink — none of it is locked in) only until the accurate track produces anything, then hands over completely. The two are deliberately **not blended**: the preview decodes its own windows, so its wording isn't an exact prefix of the confirmed text and `TranscriptMerger.partialRemainder` would fail to find the seam and duplicate the whole tail.
- **`TranscriptMerger.tidiedPreview`** repairs the preview's per-window seams for display (orphan punctuation-only tokens, window-final periods disproved by a following lowercase word). Preview only — never run it on the accurate transcript, where stripping a real sentence-final period would corrupt what gets pasted.
- **Do not "simplify" this by lowering the accurate track's `chunkSeconds`.** `finish()` reconstructs the final transcript from those same windows, so shorter windows mean less acoustic context and a worse transcript — the one thing that actually gets pasted. `AudioReplayTests.testPreviewTrackStreamsTextOnAClipTooShortForTheAccurateTrack` locks the split in: on a ~5 s clip, replayed **in real time**, the preview streams 3 updates while the accurate track streams 0, and `stop()` still returns the full accurate transcript. Models download on demand into `~/Library/Application Support/FluidAudio/Models/<cacheDirectoryName>`; `TranscriberEngine.isInstalled` is a filesystem check, so callers must not cache it. (The removed cleanup pass above was the *Apple Foundation Models* one; a separate **opt-in MLX qwen cleanup** was later added — see below.)

### On-device Smart cleanup (MLX — opt-in, off by default)

Optional post-ASR cleanup by **S1-mini by Superwhisper** via MLX — a 0.6B text
normalizer fine-tuned from Qwen3-0.6B, converted here to 4-bit (335 MB on disk,
~293 MB archive). **The name is a licence term**: Apache 2.0 plus one condition, that
wherever it is used it keeps the name "S1-mini by Superwhisper" with that exact
capitalization, which is why it appears verbatim in `CleanupPrompt`, the Settings copy
and the archive's `NOTICE.txt`. It replaced qwen2.5-3B-Instruct, which was a general
instruct model doing this job badly enough that the pass had to be off by default:
measured end to end through the app on `eval/text-cleanup/cases.jsonl` (shipped
output, i.e. the guard's verdict applied), the 3B scored **85/89 at ~250 ms and
1.5 GB**, and S1-mini scores **87/89 at ~100 ms and 335 MB** — better, a quarter the
size, and well under half the latency. The two it still misses are `vocab-acronym`
and `corr-name-chain`, both of which the 3B missed too, and the second of which is
already documented above as a known limitation. **Three format rules are load-bearing and every
integration bug traces to one**: the system prompt is the exact trained string (not a
prompt to tune), the user turn opens with a `[Styling: …] [Structure: …] [Context: …]`
control line, and **`enable_thinking` must be false** — it is a Qwen3 template, so
left on, every reply arrives wrapped in `<think>` and the guard rightly rejects all of
it (`MlxCleanupService.templateContext`, plus a stripping fallback in `sanitize`).
**"Polish my English" became "Formal styling"**: S1-mini normalises and does not
restructure sentences, so the copy no longer promises a rewrite it will not perform.

**⚠️ The agent and the intent classifier keep a general instruct model, deliberately.**
`AgentLoop.liveGenerator()` and `classifyIntent` pass their own tool-calling prompts
and parse structured answers back; S1-mini's card is explicit that it is not a chat
model and will not follow general instructions. Pointing them at it **fails silently,
not loudly** — the agent returns normalised prose, no tool executes,
`CommandAgentService` correctly reads that as "did not act", and the whole assistant
degrades to the keyword gate forever. So they use `MlxCleanupService.general`
(`CleanupModel.General`, still the qwen archive) via `prepareGeneralIfInstalled()`,
which **loads it only when it is already on disk and never downloads it** — an
existing install keeps its assistant, and a new one is not made to fetch 1.5 GB for a
feature it may never touch. Giving that its own download affordance is the obvious
follow-up. Two Settings toggles: **Smart cleanup** (`llmCleanupEnabled` — light: fix self-corrections/false starts) and **Polish my English** (`llmGrammarPolishEnabled` — heavier rephrase to grammatical English). Dictation **never waits** on it: the deterministic text pastes instantly and, on the **native** path, the qwen polish refines it *in place* a beat later (`scheduleRefinement`); on the **web/Electron** path (no safe in-place edit) polish is computed *before* the ⌘V. Pieces:
- **`MlxCleanupService`** (`actor`) — loads the model once and reuses a persistent system-prompt **KV cache** (feeds only the per-call delta). `clean()` returns `nil` on any problem so the caller keeps the deterministic text — cleanup can only ever help, never block. The load is **timeout-bounded (`loadTimeoutSeconds` 60 s) and retried** by the manager: a stalled MLX/Metal init (seen under launch-time GPU contention) used to wedge the state `.loading` forever, so Settings showed "Preparing…" indefinitely while polish silently no-op'd. Load/prime timing is logged.
- **`CleanupModelManager`** (`@MainActor`, owned by `DictationViewModel`) — reconciles the toggle each refresh tick, drives the **mirror-first background download** (`ModelInstaller`, R2 archive `Qwen2.5-3B-Instruct-4bit`, HF fallback), retries the load up to 3×, and surfaces status to `AppState`: `cleanupModelReady` / `cleanupModelFailed` (→ Settings shows **"Couldn't load — Retry"**, `cleanupRetryRequested` re-attempts) / `cleanupModelReadyAt` (one notch banner). Progress shows **only in Settings**.
- **`CleanupFaithfulnessGuard`** (pure, `CleanupFaithfulnessGuardTests`) — rejects the LLM output (→ keep deterministic) when it **invents** content (answers/translates/codes/injects), balloons, or grossly truncates; `allowRephrase` loosens it for polish mode. **Known limitation, do not "fix":** it catches *added* content but not a *dropped* content word ("meant to be born" → "meant to be"). A deterministic word-counter can't tell that from a legitimate self-correction ("john i mean jane" → "Jane") or compression ("gonna go" → "going") — a content-retention rule was tried and **reverted** because it rejected those. So polish occasionally drops a word; that's why "Polish my English" is **experimental/off-by-default**. Verify any cleanup change against the real pipeline via `eval/text-cleanup/run-eval.sh` (it grades the shipped passes + both LLM modes + the real guard).

**Model install is mirror-first.** `ModelInstaller` (in `ModelInstall/`, with `BackgroundFileDownloader` + `DownloadResumeStore` + `Archive`) is archive-based — `installIfNeeded(archiveName:destinationRoot:label:maxAttempts:isInstalled:onProgress:)` downloads `<archiveName>.zip` from the public R2 bucket and unpacks it into `destinationRoot`, with an accurate % (R2 returns a real `Content-Length`). It **retries** the download+unpack (`maxAttempts`, default 2). The download is **resumable**: `BackgroundFileDownloader` uses a **background `URLSession`** (owned by `nsurlsessiond`, keyed by a fixed identifier) writing to a *stable* path `<destinationRoot>/.downloads/<archiveName>.zip`, so an interrupted 1.5 GB transfer resumes instead of restarting from zero — it reattaches to a transfer the daemon kept running across an app quit, else resumes from persisted `NSURLSessionDownloadTaskResumeData`, else starts fresh. `DownloadResumeStore` persists the URL→destination map (so a transfer the daemon finishes while the app is quit is moved into place on the next launch) and the resume token, both under `.downloads/`; `AppDelegate` touches `BackgroundFileDownloader.shared` at launch so replayed completion events drain before any new download decision. Timeouts are **bounded** (120 s stall / 24 h resource, not the 7-day URLSession default). Only after retries are exhausted does it fall back to FluidAudio's HuggingFace download — and that fallback is **loud, not silent**: logged at `.error` via `Log.modelPrep` (subsystem `app.whispermaster.mac`, persisted to the unified log) and surfaced in the UI (`AppState.usingFallbackModelSource` → "downloading from backup source (slower)"). Note `TranscriberEngine.isInstalled` validates the **actual compiled files** (each required `.mlmodelc`'s `coremldata.bin`), not just that the folder exists — a half-deleted/partial install correctly re-fetches from the mirror instead of masquerading as ready (which used to drop it to the slow HF path). This whole chain was the cause of the intermittent "model loading stuck" bug: a bare-folder `isInstalled` + silent HF fallback + no download timeout. A `TranscriberEngine` convenience overload covers the main engine (`DictationViewModel.installModelsFromMirror`, before `prepareModels`); the CTC vocabulary model uses the generic form. **Both the engine model and the CTC model are hosted on R2.** To publish/refresh an archive: from the models root (`~/Library/Application Support/FluidAudio/Models`), `ditto -c -k --keepParent <dir> <dir>.zip`, then upload to `whisper-master/models/` on R2 (same creds as `release.sh`).

**Custom vocabulary (biasing).** Users maintain a glossary — `PrototypeAppState.customVocabulary` (persisted under `WhisperMaster.customVocabulary.v1`), edited in the Voice-engine **"Words to get right"** field (a raw `@State` draft parsed one-way to `[String]`; don't reintroduce a normalizing two-way binding or Enter/multiline breaks). `FluidAudioStreamingTranscriber.setVocabulary` stores terms (cheap); `loadVocabularyResources` loads FluidAudio's CTC keyword model (R2-first, ~89 MB, guarded against duplicate loads) in the **background** and calls `configureVocabularyBoosting`, biasing decoding toward those terms (e.g. "RAG" not "rack"). It's warmed right after the main engine is ready (`refreshCustomVocabulary`) and re-applied after each session's manager recreation in `stop()`/`cancel()`, so it never blocks recording and is best-effort. Biasing is CTC acoustic rescoring with thresholds — short acronyms are the hard case; tune via `CustomVocabularyTerm` weight/aliases if needed.

### Reading answers aloud (`Speech/`)

An assistant answer is **spoken as well as shown**. Only answers reach this — a dictation is never read back. `Speech/` is playback and must stay separate from `Audio/`, which is the capture graph and carries the device-juggling prohibitions below: **nothing here touches `AVAudioEngine` or any Core Audio HAL property**, which is what makes it safe to run beside `MicrophoneCaptureService`.

- **One choke point.** Every answer already landed in `AppState.activeDaySummary` next to a `Feedback.delivered` — the branches of `DictationViewModel.runDayQuery` and `presentAnswer`. Each also calls `speakAnswer(headline:detail:)` and `state.appendAnswer(...)`.
- **`SpokenAnswer` (pure, `SpokenAnswerTests`)** strips markdown/URLs/emoji, turns *list items* into sentences while leaving soft-wrapped prose alone (a false full stop stops the voice mid-thought), and chunks to ≤300 chars. **The chunking is load-bearing, not an optimisation** — `KokoroAneManager` throws over 512 IPA tokens. `detail` is spoken only where it carries the answer; on the agent path it's provenance chrome ("From Work Calendar"), worth seeing and not worth hearing.
- **Two backends behind `SpeechSynthesizing`.** `SystemSpeechSynthesizer` (default) is macOS's own voices — out of process in `speechsynthesisd`, so nothing measurable is resident here, and it joins the chunks back into one utterance for better prosody. `NaturalSpeechSynthesizer` (opt-in) is **Kokoro-82M via FluidAudio's `TTS/` module**, which the ASR dependency already ships — no new package, no version bump. It runs the heavy stages on the **ANE**, so it doesn't fight the 1.8 GB MLX qwen for Metal memory, and `cleanup()` unloads it after `idleUnloadSeconds` (120 s) so the footprint is transient. It synthesizes sentence *n+1* while *n* plays.
- **Silence is never an outcome.** Not installed, cold, load threw, synthesis threw → the system voice takes the remaining sentences. Same posture as `MlxCleanupService` returning `nil`: the optional thing can improve the result, never remove it. A **cold** natural voice deliberately lets the system voice take that answer and warms in the background rather than making the user wait seconds for the first word.
- **⚠️ The natural voice's models must land in `~/.cache/fluidaudio/Models/`**, *not* the app's `Application Support/FluidAudio/Models/` root. `KokoroAneManager.initialize()` resolves the shared G2P assets through the `G2PModel.shared` singleton, which hardcodes that path — FluidAudio's own source warns that honouring a custom `directory` downloads somewhere `G2PModel` can't see and then fails with an opaque `vocabLoadFailed`. Two archives (`kokoro-82m-coreml`, `kokoro`), pulled mirror-first with the generic `ModelInstaller.installIfNeeded`; publishing recipe is in `NaturalVoiceInstaller`'s doc comment.
- **The banner's clock pauses while the voice runs.** `AppDelegate`'s 0.5 s tick pins `daySummaryAt` to now whenever `isSpeakingAnswer`, so a thirty-second answer can't outlive its own caption; `AppState.daySummaryWindow` then leaves a `spokenAnswerTailHold` (4 s) tail. Exactly the trick `dueReminderAt` uses. **`viewModel.reconcileSpeech()` on the same tick is the required backstop** — with the clock pinned, a speaking flag that never cleared would hold the band open forever, so it reconciles against the speaker's own view of whether it's running and enforces a `maxHoldSeconds` ceiling.
- **`applicationWillTerminate` is not polish.** Playback is out of process; quitting mid-utterance can leave the Mac talking with nothing on screen to explain it.
- **Barge-in happens before the mic comes up** — `startRecording` calls `answerSpeaker?.stop()` alongside `reminderScheduler.clear()`, so reaching for the key both cuts the voice off and keeps it out of the transcript. Speech also declines entirely while `phase != .idle` (an answer can land after a new dictation has already started, and talking into a live mic puts the app's own voice in the transcript) and while **VoiceOver** is on (it's already reading the banner).
- **One switch, because there is one consent.** `speakAnswersEnabled` is **on by default**: you asked out loud, so an answer you can hear is the expected outcome, and only the chord reaches it — never ordinary dictation. It was two switches, the second guarding *unprompted* speech from a scheduled automation; automations are gone, so nothing can talk without being asked and the second switch went with them. Its defaults key (`WhisperMaster.speakAutomationAnswers.v1`) is left on disk and never read — don't reuse the name.
- **`AnswerLog` / Today → "Recent answers"** is where an answer becomes readable. The notch line is single-line and truncated (`NotchBannerRow` sets `.lineLimit(1)`) and a day query deliberately skips `appendHistory`, so without it a long answer is simply unrecoverable.
- **`AnswerSpeaker` never writes `AppState`**; it reports through callbacks and `DictationViewModel` records, per the rule below. It's created **on the first answer that wants speaking**, never at launch — `swift test` and the headless snapshot renderer both construct an `AppState` and neither should instantiate an `AVSpeechSynthesizer`.

### Recording lifecycle (PrototypeViewModel)

`startRecording` → `prepareSelectedEngineIfNeeded` (model download with progress callbacks updating `state.download`) → `transcriber.start(updateHandler:)` → `microphoneCapture.start(...)`. Audio buffers from the mic tap are funneled through `enqueueAudioBuffer` which spawns a per-buffer `Task` so the tap callback never blocks; `drainPendingAudioBuffers` awaits them all on stop. There's an intentional `releaseTailNanoseconds` sleep on stop to let the last audio frames flush before tearing down — don't remove it.

**Microphone capture + the Bluetooth "call mode" issue (`MicrophoneCaptureService`).** A Bluetooth headset can't do hi-fi A2DP playback and mic input at once — the moment any app records from its mic, macOS forces it into the low-quality **HFP "call" profile** (mono, ~8 kHz), degrading both playback *and* the signal we transcribe. This is a **hard Bluetooth limitation, not something an app can tune around.** The reliable fix is for the **user** to set their input to the built-in mic (System Settings → Sound → Input); then the earphones stay in hi-fi and dictation captures a cleaner wideband signal. **⚠️ Do NOT add code that programmatically juggles audio devices to "auto-fix" this — it was tried three times (0.3.5–0.3.6) and every variant broke something:** (1) forcing an input-only device onto `AVAudioEngine` via `kAudioOutputUnitProperty_CurrentDevice` → engine can't start when the output device differs (broke recording); (2) swapping the system default input to built-in for the recording and restoring it on stop → re-routes every recording, races ("works once then stuck"); (3) switching the default input via `kAudioHardwarePropertyDefaultInputDevice` then immediately creating an `AVAudioEngine` and reading `inputNode` HW format → **hung in Core Audio** (`GetHWFormat` blocked on `coreaudiod`, app unresponsive, couldn't even quit). The capture service is intentionally back to the simple known-good form: reuse one `AVAudioEngine`, capture from the system default input, **no device manipulation in the recording path** — leave it that way. The **safe** way to help (shipped): `BluetoothInputMonitor` (read-only poll, off-main) detects a Bluetooth default input and sets `AppState.bluetoothInputActive`; the notch then shows `NotchBluetoothBanner` ("Bluetooth mic lowers quality → Use built-in") and, only when the *user taps it*, `AudioInputDevices.switchToBuiltInMic()` does **one** `kAudioHardwarePropertyDefaultInputDevice` set off the main thread (the same op as Sound settings), while idle and nowhere near the engine. That decoupling — user-initiated, off-main, not in the capture flow — is what makes it safe vs. the auto-switch that hung. The pill panel is click-through except while the banner is up (`DictationPillWindow.setInteractive`, driven by `AppState.shouldShowBluetoothBanner` from the refresh loop).

**Route changes are the one thing capture *does* defend against (`AVAudioEngineConfigurationChange`).** Plugging in an external speaker, moving the default output, or connecting AirPods makes `AVAudioEngine` stop itself and re-derive its IO formats; anything that then touches the old graph — installing a tap with a format read a moment earlier, or starting an engine built against the previous device set — raises an Objective-C exception (`required condition is false: …`), which is an `abort()` no Swift `try` can catch. **That was the "crashes sometimes with an external speaker while using the built-in mic" report:** a mismatched input/output pair is exactly the case that renegotiates the graph, and nothing observed the notification. Three defences, none of which touches a device: (1) `MicrophoneCaptureService` observes the notification and **rebuilds the engine** (`engine` is a `var`; `reset()` keeps the stale IO formats, so a fresh object is the only reliable shed) — re-tapping a live recording, or shedding + re-warming an idle one; (2) `installTap` is passed **`format: nil`** so the node uses the format it holds *now* — the formats are still read first, but only to *reject* a graph that is visibly mid-renegotiation (`settledInputFormat`, which requires the node's `inputFormat` and `outputFormat` to agree); (3) a failed `start()` is **retried once on a fresh engine**. If a live capture can't be re-tapped, `onCaptureLost` fails the session honestly (`CaptureError.captureInterrupted`) rather than leaving a "recording" fed by silence. **Two guards stop recovery from becoming a loop, and neither is optional:** a rebuild can itself provoke another configuration change, so (a) changes arriving within `prewarmQuietWindow` of our own warm-up are treated as self-inflicted and ignored — a plain "am I warming right now" flag cannot do this, because the notification is delivered *asynchronously*, after the warm has returned — and (b) mid-recording recovery draws on `CaptureRecoveryBudget` (pure, `CaptureRecoveryBudgetTests`: N attempts per window), so a genuinely flapping route abandons the session instead of rebuilding the graph for as long as it flaps. `copy(buffer:)` also guards zero capacity / channel-less formats, which a tap can deliver mid-swap and which `AVAudioPCMBuffer.init` throws an exception on. **Rebuilding the engine object is not the same as the prohibited device juggling above** — no HAL property is ever set — so keep the two distinct when editing this file.

**Mic warm-start (safe, shipped).** A cold `AVAudioEngine.start()` pays a Core Audio HAL negotiation (**~300–500 ms**, measured via the DIAGNOSTICS traces) that clipped the first words of a push-to-talk and read as a "loader → wave" lag in the notch. `MicrophoneCaptureService.prewarm()` — called once at launch after mic permission — does a brief **tap-less** `start()`/`stop()` to bring the input driver into residency, cutting the first real `start()` to **~70 ms**; `startAutoRewarm()` re-warms on a read-only `kAudioHardwarePropertyDevices` listener so a topology change (AirPods connect/disconnect) can't leave the warm stale. This warms **our own engine only — no device manipulation** — so it stays clear of the hazards above. **AirPods-connected is an irreducible exception:** while AirPods are connected macOS re-arbitrates the Bluetooth route on *every* mic-input `start()` (~350 ms) and that cost isn't cacheable across `stop()`; the only way to kill it is a permanently-hot mic, which we don't do.

Transcript merging (`mergedConfirmedTranscript`, `partialRemainder`, `longestSuffixPrefixOverlap`) handles streaming overlap between successive partial/confirmed updates from the engine — partial transcripts can re-emit text the confirmed stream has already locked in.

### Notes: the recording is part of the note (`Notes/`)

A note made by voice keeps **three** things, not one: the assistant's tidied
`title`/`body`, the **verbatim `transcript`**, and the **`audio`** of the dictation
that produced it. "Did it hear me right?" is the first question a spoken note
raises, and the recording is the only thing that answers it without asking the user
to trust either string. UI details are in `Sources/WhisperMaster/UI/CLAUDE.md`.

- **`Note`'s `Codable` conformance is hand-written and must stay that way.** Notes
  are already on disk (and in the sync dashboard) from before pinning, transcripts
  and audio existed, and the *synthesized* conformance treats a missing
  non-optional key as a decode error. `NotesStore.loadFromDisk` swallows that throw
  — so adding a bare `isPinned: Bool` would have silently emptied every existing
  user's notes rather than crashing. Every field added from here on uses
  `decodeIfPresent` with a default;
  `NoteVoiceModelTests.testALegacyNoteWithNoneOfTheNewKeysStillDecodes` is the lock.
- **The audio tee runs for every session, not just chord-armed ones.**
  `DictationViewModel.noteAudioWriter` starts in `startRecording` and is fed from
  `enqueueAudioBuffer` (the single mic choke point). It can't start at *arm* time
  because the chord can arm a session already in flight — fn pressed a hair before
  control — which would clip the opening word off exactly the notes people dictate
  fastest. Cost is a mono int16 downmix per buffer, nothing beside Parakeet. It's
  bounded (`noteAudioMaxMs`, 5 min) so a latched hands-free session can't grow the
  heap all afternoon, and a `defer` in the stop task drops the samples for any
  session that didn't become a note.
- **This is collection, not a second capture.** The buffer is already in hand from
  the one existing tap; nothing here touches a device or `AVAudioEngine`, so it
  stays clear of the device-juggling prohibitions above. Playback
  (`NoteAudioPlayer`) is `AVAudioPlayer` on a finished file — the same
  `Speech/`-vs-`Audio/` separation.
- **Both note-creation paths carry the voice context.** The agent path
  (`LocalToolRunner.createNote`, the common case when the 3B is loaded) gets it via
  `LocalToolRunner.VoiceContext`; the deterministic fallback
  (`DictationViewModel.createNote`) passes it directly. The audio closure is
  `takeAudio`-shaped because the recording is **consumed on first use** — one
  capture yields one recording, attached to whichever note it produced.
- **Audio is deliberately not synced.** `NotesSyncClient` pushes the rows; the WAV
  stays on the Mac that recorded it. So a synced note names a file that isn't here,
  and `NoteAudioStore.playableURL` reports that rather than rendering a play button
  that does nothing. Deleting a note keeps the row as a sync tombstone but deletes
  the recording outright — it's the biggest thing the app writes and there's nothing
  for another Mac to reconcile.

### Gentle reminders (`Reminders/`)

Because the app lives in the notch with no window to return to, a user can forget it exists. The fix is a **gentle nudge reused through the existing notch surface** — not a native `UNUserNotification`: when the app has been idle a while, the black notch band drops down with a short friendly line (`NotchReminderBanner`) for ~5s, silent and click-through, then retracts. Four small pieces: `ReminderPolicy` (pure, deterministic — takes `now`, holds all tunable timing: 3h baseline → 6h → 12h backoff, daily cap, display duration), `ReminderBookkeeping` (Codable cadence state persisted under `WhisperMaster.reminders.v1`), `ReminderCopy` (the rotating lines), and `ReminderScheduler` (`@MainActor` driver, owned by `DictationViewModel` — the sole `AppState` writer — that consults the policy and sets `AppState.activeReminder`). The **AppDelegate 0.5s refresh loop** calls `viewModel.evaluateReminders()` each tick (idle-gated, cheap). A completed dictation calls `reminderScheduler.noteUsed()`, resetting backoff to the friendly baseline; `startRecording` calls `clear()` so the live indicator never collides with a reminder. Safety rests on three independent layers, not on context detection (which was deliberately dropped — no DND/Focus, meeting, or screen-share detection): the artifact is intrinsically gentle, a Settings **"Gentle reminders"** toggle (`AppState.remindersEnabled`, **on by default — opt-out**; while off the scheduler is dormant and resets its cadence so a later opt-in starts a fresh idle gap) is a hard off-switch, and the conservative cadence means few firings. Spec: `docs/superpowers/specs/2026-06-30-gentle-notch-reminders-design.md`.

**Scheduled reminders land in the notch too — Notification Centre is Sparkle's alone.** Don't confuse these with the gentle nudges above: a `ReminderItem` the user *set* (spoken or typed) fires from `AppDelegate.fireDueReminders` on the same 0.5s tick, and its `.notification` alert style now means `NotchDueReminderBanner` (bell + title + body/time, its `soundName` played once via `Feedback.reminderDue`, a **checkbox** to tick it off, tap the text → Settings → Notes & Reminders), **not** a `UNUserNotification` — a reminder stacked in Notification Centre under mail and Slack is the one thing this app said somewhere other than the notch. The `.alarm` style is unchanged (its own focused window). Two rules make it reliable: **the reminder is only marked fired once the band actually took it** (`presentReminderInNotch` returns false while the notch is busy, exactly like `AlarmController.present`, so it stays due and re-fires), and **its display clock only runs while it's on screen** — the refresh loop pushes `dueReminderAt` forward whenever `AppState.canShowDueReminderBanner` is false, so a dictation started mid-window can't expire an alert the user never saw. It outranks every passive hint and yields only to the approval card, the "when?" quick-prompt, and the undelivered hint (each awaits a tap or holds something unrecoverable). The one `UNUserNotification` left in the app is Sparkle's update reminder — keep it that way.

**A ticked reminder leaves the list — `activeReminders` and `completedReminders` are two different questions.** `NotesStore.visibleReminders` orders *everything* by due date, so while completion was only a strikethrough in place, a task finished this morning sorted above one due tonight and the list stopped answering "what's left?" the moment anything got ticked off. Completion now stamps **`completedAt`** (Optional — `ReminderItem` keeps the *synthesized* `Codable` and only stays decodable for existing rows because of that; a non-optional field here would empty every store the way it would for `Note`) and the store exposes two queries: `activeReminders` (not completed, soonest-due first — what every surface shows) and `completedReminders` (the archive, **most-recently-finished first**, because it's read to confirm something just got done and to undo a mis-tick, not to recall when it was scheduled). `clearCompletedReminders()` empties the archive with tombstones, not dropped rows, so a clear survives a pull-merge. A **repeating** reminder never lands there — `completeReminder` rolls it forward and clears the stamp — which is why the Settings checkbox promises "next <date>" before the tap rather than explaining the surprise after it.

**The notch checkboxes tick both ways, and the undo is snapshot-based.** Both surfaces that show a reminder on the bezel — the due banner and the quick-actions "Next up" column — let the user check *and* un-check without opening the window: a one-way tick on a panel with no undo affordance means a mis-click can only be fixed in Settings. Ticking goes through `NotesStore.completeReminder`; un-ticking goes through **`NotesStore.restoreReminder(_ snapshot:)`**, which takes the pre-tick *copy* rather than an id — **`completeReminder` is not a flag flip**: a repeating reminder rolls forward to its next occurrence instead of completing, and only the caller that ticked it still holds the occurrence that was rolled away. For the same reason the checked state is held by the caller (`AppState.dueReminderCompleted`; `NotchQuickActionsModel.ticked`) rather than read back off `isCompleted`, which stays false for a repeat. `restoreReminder` deliberately stamps `firedAt` on an already-due reminder so the poll loop can't announce it a second time, while leaving a future one armed. A ticked banner swaps its window for the short `dueReminderAnsweredHold` undo window; a ticked quick-actions row stays in place, struck through, until the glance ends (`ticked` clears whenever the panel closes).

### Open at login (`App/LaunchAtLogin.swift`)

Backed by `SMAppService.mainApp`; the OS (System Settings → General → Login Items)
is the source of truth. Two things here are load-bearing and were both causes of
"it doesn't start after a restart":

- **`.requiresApproval` is a third state, not "off".** `register()` can succeed while
  macOS holds the item until the user approves it — registered, `status != .enabled`,
  and it does **not** launch at login. It's surfaced as `needsApproval` (onboarding
  beat + a Settings hint, each with a one-tap `openLoginItemsSettings()`), never
  collapsed into off, and it deliberately does **not** satisfy the onboarding beat.
- **`reconcileOnLaunch()` re-registers a registration the OS lost.** A Login Items
  record is tied to the bundle's signature and location, so a Sparkle update, a
  re-signed local install, or a move drops it to `.notRegistered` with no error and no
  UI — the app just silently stops opening at login. The user's own answer is persisted
  (`launchAtLogin.intent.v1`) and re-applied at launch, so this only ever heals in the
  direction they already chose; it can never add a login item on its own.

The ask lives in **onboarding** (`NotchOnboardingStep.openAtLogin`, beat 3 of 4), not
only in Settings — a dictation app whose shortcut does nothing after a reboot reads as
broken. Existing accounts are not re-onboarded (`OnboardingProgress.isComplete` is
unchanged); they get the Settings toggle plus the approval hint.

### Analytics (`Analytics/`, opt-in, account-linked)

Opt-in (on by default, one-tap opt-out in **Settings → General → "Share usage data"**) product analytics, fanned out to **two sinks**: **PostHog Cloud** (product analytics — funnels, retention; free tier, replaced TelemetryDeck) and **Google Analytics 4** (the same events in the same property as the landing page, so site visit → download → activation reads as one story instead of two disconnected dashboards). **One vendor seam:** only `Analytics.swift` knows either vendor exists, so adding/swapping/dropping one is a change to that file. Pieces:
- **`AnalyticsEvent`** (pure, SDK-agnostic) — the whole event catalog with **both** wire spellings + content-free params. **Nothing carries user content** — only app version, coarse buckets (duration/word-count), and enum-like states; numbers are bucketed so no signal is fingerprintable. Events: `App.launched`, `Onboarding.finished`, `Dictation.completed`, `Permission.state`, `Update.installed`, `Cleanup.modelDownloaded` (fired from `CleanupModelManager` when a user actually pulls the ~1.5 GB LLM — the "how many adopted Smart cleanup" counter), `App.crashed` (see Crash reporting below). GA gets the snake_case `googleName` of each (`app_launched`, …) because **GA4 rejects dotted names**, and the PostHog names can't be renamed under live dashboards; **params stay one catalog** and are snake_cased for GA by `GA4Limits.parameterName`, so nobody maintains two dictionaries.
- **`Analytics`** (`@MainActor` singleton) — gates every send on the opt-in, then fans out to each **independently-configured** sink. Lazily `setup`s PostHog on first enable and `optIn()`/`optOut()`s on toggle; builds the GA client on first enable. Autocapture (lifecycle + screen views) is **off** — a menu-bar app has no UIKit surface, so the stream is just our explicit events.
- **⚠️ Analytics is identified, and stopped being anonymous on purpose.** `AnalyticsIdentity.installID` (a random persisted UUID) is only the *pre-sign-in* identity now. Once Clerk resolves, `Analytics.identify` sets PostHog's `distinct_id` to the **Clerk user id** and puts the **email and name** on the person profile (`AnalyticsAccount`), because "which customer uses which feature" is unanswerable from a per-install UUID — one person on two Macs is two users. `alias(installID)` joins the pre-gate events (launch, permission state, onboarding) to that person, or the activation funnel breaks at exactly the step it measures. GA keeps `client_id` = install id and gains **`user_id`**: GA models those as device and person, and overwriting `client_id` mid-stream forks that Mac's session history (set Admin → Reporting identity to Blended/Observed or GA keeps counting devices). Sign-out calls `reset()` then re-asserts the install id, so a second user on the same Mac doesn't inherit the first one's profile. **Three consequences that must stay true:** the *events* stay content-free and account-free (`AnalyticsTaxonomyTests.testNoEventParameterCarriesAccountIdentity` is the lock — the identity lives on the profile alone, so an exported event stream is not a customer list); the Settings copy says **"Share usage data"**, never "anonymous"; and the landing page's `lib/legal.ts` flow + privacy retention paragraph say account-linked. Those three moved together and must keep moving together. The **on-by-default** posture predates this and is a weaker argument for account-linked data than it was for anonymous counts — worth revisiting.
- **Every signal carries a `category` (`AnalyticsCategory`)** — `lifecycle`, `dictation`, `assistant`, `notes`, `reminders`, `connectors`, `speech`, `cleanup`, `settings`, `reliability`. It is appended in `parameters` unconditionally, after the per-case params, so a new case can neither forget it nor shadow it, and "what is this account actually using?" is one breakdown rather than a hand-maintained list of event names. **Instrument the choke point, not the surface**: pinning, completing and restoring are emitted from `NotesStore`'s mutators rather than the canvas/quick-actions/notch call sites, so the surface added next is covered for free. Per-user *totals* ride the person profile instead of the event stream (`Analytics.updatePersonProperties`, written beside `usageStore.record`) — PostHog can cohort on a person property directly, where a per-user feature tally otherwise means aggregating that account's whole event history.
- **`GoogleAnalyticsClient`** (`actor`) — GA4 over the **Measurement Protocol**: a plain HTTPS POST, **no dependency**. Deliberately not Firebase — GA4 has no native macOS SDK, and `FirebaseAnalytics` (macOS still beta) would put a closed-source `GoogleAppMeasurement` binary + a `GoogleService-Info.plist` inside an app that promises nothing leaves your device. Three things the protocol makes us do by hand: **`session_id` + `engagement_time_msec` on every event** (`GA4Session`, pure + clock-injected) or GA files each hit under a zero-second session and every standard report stays empty while Realtime looks fine; **app/OS version as explicit params**, since a native app sends no User-Agent GA can enrich (register them under Admin → Custom definitions or they're invisible outside a single event); and **client-side limit clamping** (`GA4Limits`), because **GA's production endpoint answers `204` for a payload it is about to discard** — a violation surfaces as missing data weeks later with nothing logged. Set **`WHISPERMASTER_GA_DEBUG=1`** to POST to `/debug/mp/collect` instead and get the actual rejection reason in the `analytics` log category. Sends are detached and failures dropped: an analytics hit is never in the path of a dictation finishing. `URLSession` is ephemeral — no cookies, no cache.
- **`AnalyticsConfig`** — PostHog project API key (`phc_…`) + host (US cloud default), and the GA4 `G-…` measurement ID + Measurement Protocol API secret. All overridable by env var (`WHISPERMASTER_POSTHOG_API_KEY`, `WHISPERMASTER_POSTHOG_HOST`, `WHISPERMASTER_GA_MEASUREMENT_ID`, `WHISPERMASTER_GA_API_SECRET`) for dev, else baked into Info.plist by `bundle.sh` from `.env` / CI secrets (`POSTHOG_API_KEY`, `GA_MEASUREMENT_ID`, `GA_API_SECRET`). **Each sink stays fully dormant until its own credentials are set** (no init, no network), so a build with one configured sends only to that one. The measurement ID is shape-checked (`^G-[A-Z0-9]+$`) because an unsubstituted `$(GA_MEASUREMENT_ID)` is a non-empty string GA would accept and then silently drop every event for.
- **⚠️ The GA API secret is not publishable the way the PostHog key is.** It ships in the bundle and is extractable from any downloaded `.app`. The exposure is bounded — it can only *write* events into one GA data stream, never read anything or reach another Google service — but **give the app its own data stream** so revoking a leaked secret never touches the website's analytics, and so desktop sessions don't blend into web sessions.
- **`channel` is a dimension, not a separate data stream — that's what makes stable/beta comparable.** All three channels post to the **one** GA data stream (`whisper-master-mac-app`, a **Web** stream — only web streams have a `G-…` measurement ID; iOS/Android streams are Firebase-backed and want a different payload entirely) and to the one PostHog project, split by a `channel` param on every event. Per-channel *streams* were rejected: they'd isolate the data but destroy the one report that matters most — beta vs stable side by side — and cost 3 secret pairs in CI. **The value comes from `ReleaseChannel.current` (the bundle id this binary shipped with), never `BetaAccess.currentChannel`** (which answers "which appcast should Sparkle poll", needs a signed-in Clerk user, and reports `.beta` for a *stable* build run by a flagged user — attributing that user's events to beta would corrupt both channels' counts). PostHog gets it **twice, deliberately**: as a super property (`register`, splits *events*) **and** as a person property on `identify` (splits *users* — PostHog's unique-user and retention maths runs off the person profile, so a channel that only exists on events can't be a cohort). It also makes local `dev` builds filterable; without it every developer relaunch inflates the stable numbers with no way to exclude it after the fact. **Register `channel` under GA Admin → Custom definitions** — a GA custom dimension can't be renamed without losing its history, so the spelling is fixed at first registration.
- **Native crash capture rides the PostHog SDK — no new dependency, no new vendor.** `posthog-ios` vendors **PLCrashReporter**, so `config.errorTrackingConfig.autoCapture = true` in `Analytics.initializeSDKIfNeeded` buys Mach-exception + POSIX-signal + uncaught-`NSException` handlers, persisted to disk and sent as `$exception` on the next launch with a symbolicated stack. `inAppIncludes = ["WhisperMaster"]` marks our frames in-app (the app is *renamed* per channel, so the SDK's inference off the bundle name is not to be trusted). Sentry was scoped and deliberately **not** adopted: it's better at triage and release health, but it's a third telemetry vendor to disclose in an app that promises nothing leaves your device, and this covers the crashes we actually have. Three things are load-bearing: **handlers install during `setup`, which only runs when the user has analytics on**; **`optOut()` uninstalls them** (`optIn()` reinstalls), so the Settings toggle tears the handler down rather than muting it; and **`Analytics.shared.configure` runs at the very top of `applicationDidFinishLaunching`** — after the engine graph and Metal warm-up, a handler would miss exactly the launch crashes worth catching. It reads `AppState.persistedAnalyticsEnabled` (a `nonisolated` `UserDefaults` read) rather than `viewModel.state`, because touching the lazy view model there would drag the whole engine graph up the launch order. **Two switches outside the code must both be on or this silently does nothing:** *autocapture exceptions* in the PostHog project settings (the integration checks `remoteConfig.isAutocaptureExceptionsEnabled()` and **skips install with nothing logged** when off), and the dSYM upload below. Crash capture is also **disabled under a debugger** by design — don't test it from Xcode and conclude it's broken.
- **⚠️ A release whose dSYM never uploaded is permanently unsymbolicated.** `Scripts/release.sh` shells out to the uploader **vendored in the posthog-ios checkout** (`build-tools/upload-symbols.sh`) so the CLI flags track the SDK instead of being hand-rolled, and it runs **before notarization** — a failure there costs a rebuild rather than a burnt version number. It needs `posthog-cli` (npm, ≥ 0.7.7; CI installs it) and `POSTHOG_CLI_API_KEY` / `POSTHOG_CLI_PROJECT_ID` — **a personal API key, unlike every other analytics credential here: it is not shipped in the app and not publishable, so scope it to `error_tracking:write` alone.** The Xcode build settings the uploader would otherwise read are **all wrong for this** and are overridden explicitly: `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml` are inert (Info.plist is the authority) and `PRODUCT_BUNDLE_IDENTIFIER` is always the *stable* id, because `bundle.sh` re-badges beta/dev on the staged copy **after** the build — so without the override a beta's symbols would attach to the stable release. `project.yml` now pins `DEBUG_INFORMATION_FORMAT` per config (`dwarf-with-dsym` Release, `dwarf` Debug); it matched Xcode's default already, but a wrong value here is invisible until crashes arrive as hex months later. A missing token **warns loudly and ships anyway** — the dSYM dies with the build directory, so it cannot be uploaded retroactively.
- **Crash *counting* is a separate, deliberately redundant layer (`CrashReporter` + `CrashReport`).** It is next-launch detection, not an in-process handler. The crashes this app actually suffers are the ones a handler cannot catch: an Objective-C exception out of `AVAudioEngine` is an `abort()`, and the field crash on stable 1.0.1 was an `EXC_BAD_ACCESS` inside `AGXMetalG17G` with MLX frames below it — kernel-level, dead before any Swift runs. `NSSetUncaughtExceptionHandler` sees neither, and allocating or opening a socket inside a SIGSEGV handler is a second crash waiting to happen. The OS has already written a full report by the time we relaunch, so we read *that*. **Two signals, reported together, because neither is sufficient alone:** a `UserDefaults` sentinel (`markLaunch` at startup / `markCleanExit` in `applicationWillTerminate`, which macOS calls for ⌘Q and logout but never for a crash) says *whether* the last run died; the newest matching `.ips` in `~/Library/Logs/DiagnosticReports/` says *what happened*. **`hasReport` travels with the event and must stay** — an unclean exit is also what a Force Quit, a kernel panic, and an unreadable diagnostics directory look like, so collapsing the two would inflate the crash rate with every user who ever force-quit. Dedup is by Apple's `incident_id` (persisted), or the same weeks-old `.ips` re-reports on every unclean exit and the crash count climbs on its own. **Why both this and PostHog's capture:** they answer different questions and fail differently. This one feeds GA, so crash rate per channel reads in the same dashboard as downloads and activation; it sees crashes that happen *before* the SDK initializes; it needs no dSYM to be useful; and it survives PLCrashReporter itself failing. PostHog carries the stack you debug from, this carries the rate you watch. Delete it only if it proves to be pure duplication in the field — it's two files and one event.
- **What the crash parser must and must not do.** An `.ips` is **two JSON documents concatenated with a newline** (header then body) — `JSONSerialization` won't read that as one, which is why the split comes first. It is also **full of the account name** (`procPath`, `userID`, the report's own filename), so `CrashReportParser` reads only the exception type, signal, version, incident id, and frame symbols, and `CrashReportTests` asserts no `/` ever reaches the wire. Two rules were each found by running the parser over **real** reports on a dev machine, and both have regression tests: (1) Apple writes `<deduplicated_symbol>` for a coalesced symbol — it shortens to nothing, so that frame is skipped for the informative one below it; (2) preferring our own binary over the top frame is right (a Metal frame on top collapses every unrelated GPU fault into one bucket) **but only within `ownFrameSearchDepth`** — every stack has our `main` at the bottom, so without the limit an uncaught AppKit exception during view layout signed itself `WhisperMaster!main`, useless as a grouping key and wrong about whose bug it was. Symbols are shortened by dropping template args and the argument list, because the real MLX symbols run to several hundred characters and GA truncates at 100 — a raw truncation makes sibling overloads indistinguishable.
- **App Store Connect "App Analytics" is not available to this app and no code pretends otherwise.** It only reports on App Store / TestFlight distribution; Whisper Master ships notarized direct-download via Sparkle + R2. Impressions/downloads/installs therefore have to come from the landing page's GA + the R2 download counts. This changes the day the app is listed on the Mac App Store, not before.

### UI

Theme/design-system and notch-surface rules live next to the code they govern:
**`Sources/WhisperMaster/UI/CLAUDE.md`** (loaded when you work under `UI/`). New UI
uses `Theme.swift` tokens and the `UI/Components/` ladder, never ad-hoc literals.

### Text injection

`TextInjector` (actor) synthesizes keystrokes via `CGEvent` in 20-UTF16-unit chunks. Requires Accessibility permission; the view model gates injection on `permissionsManager.accessibilityGranted()` and surfaces a "copied to clipboard, enable Accessibility" message on miss rather than failing silently.

**Paste routing (`pasteFinal` + `FocusedElementInspector`).** Auto-paste picks a mechanism from what Accessibility reports at the focused element: a settable / text-role field → instant per-char keystroke inject + in-place refine (**native**); an element with **no caret** (`kAXSelectedTextRange` absent), not settable, not a text role → **nowhere to type** → clipboard + the `NotchUndeliveredBanner` "press ⌘V" hint (`focusHasNoTextTarget`); anything else ambiguous (a web/Electron field exposes a caret even when AX won't label it a text field) → a real **⌘V** (`TextInjector.pressCommandV` via `pasteViaClipboard`), which web content honors where per-char `keyboardSetUnicodeString` is dropped. `pasteFinal` returns the text it *actually* pasted (polished on the web/terminal path) so the diagnostics trace records reality, not the pre-polish string. **Chrome hides its AX tree by default** (focused element reports `role=none` whether or not a text box is focused), so the nowhere-to-type banner can't fire there without risking the working paste — a known gap; the text still lands in history (tray → paste last).

**Terminals always take the ⌘V path (`TerminalApps`, outcome `terminal`).** A terminal emulator is the one target that *always* has a real paste destination (the shell) but doesn't advertise it via AX like a native field: GPU/custom terminals (Ghostty, Warp, Alacritty, kitty, WezTerm) expose no caret/role/settable value → they'd be misread as **nowhere to type** and the transcript would be copied but never pasted; AppKit terminals (Terminal.app, iTerm2) report `AXTextArea` → they'd take the per-char inject path, which terminals drop (they key off virtual keycodes, not synthesized Unicode). So `pasteFinal` checks `TerminalApps.frontmostIsTerminal()` (an explicit bundle-id allow-list — extend it as new terminals appear) **first**, skips both AX-role branches, and routes to `pasteViaClipboard` (real ⌘V, polish computed up front like the web path — never in-place-refine a live command line). This was the cause of "dictation doesn't paste into the terminal." **macOS Secure Keyboard Entry** (Terminal's menu, or any focused password field) makes the WindowServer swallow synthesized ⌘V too — `TerminalApps.secureKeyboardEntryEnabled()` (`IsSecureEventInputEnabled`) detects it so the status message can explain the block instead of failing silently; nothing in code can bypass it. **Debug/dev builds need their own Accessibility grant:** `dev-install.sh` rebrands to bundle id `app.whispermaster.mac.dev` and re-signs ad-hoc, so TCC treats it as a different app from the installed Release "Whisper Master" — grant "Whisper Master Dev" in System Settings → Privacy → Accessibility (and re-toggle after a rebuild if a stale grant leaves `AXIsProcessTrusted()` true while events are dropped), or auto-paste silently fails everywhere.

### Coding agents in the notch (`Agents/`, `UI/Agents/`)

The notch answers for **coding agents running on this Mac**: when Claude Code needs
permission to run something, the band drops with the question and three answers, so
a person watching a video can settle it without going to find the terminal. The whole
feature is **interrupt-first** — nothing here is summoned, and it adds **no keyboard
shortcut at all**.

- **The app is a client, never a host.** It does not ship, start, install or
  supervise [kunai](https://github.com/HEGADE/kunai) (the Go server that drives
  `claude` over its stream-json control protocol and re-publishes the result). If a
  server answers, the surface lights up; if not, the feature is simply absent, which
  is the state on almost every install. Bundling it was considered and rejected:
  kunai self-updates from its own releases and installs itself as a launchd service
  on a fixed port with its own data dir, so a second copy inside this app would fight
  the one already there over the port, `~/.kunai`, and the `~/.claude/commands/kunai.md`
  slash command kunai rewrites on every boot.
- **⚠️ Sessions live on the machine that runs them, and so does the fleet socket.**
  `GET /api/machines` lists the fleet (`{id,label,url,self}`); `GET /api/sessions` and
  the fleet push both read the **local** session manager, so a client that talks only
  to its own Mac sees only its own Mac however many machines are registered. kunai's
  own note says it — "the fleet socket: one per machine" — and its web app opens one
  against each machine's origin, which is why `handleFleetWS` allows a peer's origin.
  `AgentFleet` does the same: a socket per machine, each machine's sessions in **its
  own bucket** (one flat list would mean the last push to arrive deleted every other
  machine's agents), merged into one list with this Mac's first. A dropped socket
  **keeps** that machine's sessions until the machine leaves the list — a blip is far
  commoner than a machine ceasing to exist, and clearing would make its agents vanish
  and return. **The local machine is reached through ordinary discovery, not its
  advertised tailnet URL** (loopback beats a round trip to reach ourselves, and
  survives Tailscale being down); every other machine uses the URL it advertises. A
  session's `/ws/app/{id}` and its "Open in kunai" link both resolve against **its**
  machine, and the surfaces label a session only when it is *not* on this Mac.
- **Two sockets, never one per session — the shape kunai's own web app uses.**
  `GET /ws/fleet` pushes *every* session's state, coalesced and seeded on connect, in
  the **same `SessionMeta` shape `GET /api/sessions` returns** (kunai shares the two
  deliberately, so a push can't drift from the fetch). `GET /ws/app/{id}` carries the
  one conversation being read. Adopting the fleet push is a **correctness** change,
  not a performance one: while the list came from a 3s poll it was permanently behind
  the per-session socket and the two disagreed — a finished turn flipped back to
  `running` on the next poll, a blocked agent went unnoticed for seconds, and the band
  flickered between two clocks reading the same session. `applySessions` is the one
  merge both sources run through; the poll drops to `KunaiPollCadence.background`
  (20s) once the push lands and back to `.live` (3s) if it drops, because its only
  remaining job is noticing a server return.
  - **A second `/ws/app/{id}` opens for a neighbour that is blocked, and only for
    that.** The fleet push says *which* session is asking; the question and its
    arguments exist only on that session's own stream, so without this a blocked agent
    could not raise its card until you tapped across. It carries **permissions only** —
    transcript, reply, change set and mode all stay with the focused session, so the
    band can never show two conversations. `askOwner` records which socket raised the
    card because the answer has to go back down *that* one (`sendToAskOwner`);
    resolving a request id on the focused stream would leave the blocked session
    blocked.
  - **Opening a session adopts what it already said** (`reveal(adoptExistingReply:)`).
    kunai replays the ring buffer on attach, so the log already holds the tail — this
    lets it populate the reply band, but **only** for a session opened on purpose and
    only while it is idle. It is false for a *send*, because the previous turn's answer
    replaying as though it were this one's is exactly the ghost reply that used to
    flash up, and false for a running session, which would put a finished reply beside
    an agent still working.
- **⚠️ Discovery reads `<dataDir>/url`, and must not assume loopback.** kunai records
  its own public URL there on each boot, and its `/kunai` slash command reads that
  file rather than baking an address in. `KunaiEndpoint.candidates` does the same:
  `KUNAI_URL` → `~/.kunai/url` → `~/.kunai-nightly/url` → `http://127.0.0.1:8443`.
  The first version assumed loopback HTTP and **found nothing on a real machine**: with
  a tailnet and MagicDNS, `install.sh` mints a certificate and binds the *tailnet IP*,
  so the server is at `https://<host>.<tailnet>.ts.net:8443` and 127.0.0.1 is dead.
  The socket scheme therefore follows the base URL (`wss` for `https`) — asking for
  `ws` against a TLS server fails the upgrade rather than downgrading. `KunaiRESTClient`
  remembers whichever candidate answered and `AgentSurfaceController` opens the socket
  against **that same one**, so a machine running both the stable and nightly channels
  can't read its sessions from one server and attach to the other.
- **No credentials anywhere, and that is a property of the perimeters, not an
  oversight.** Loopback is never locked (a forgotten PIN has to stay fixable from the
  machine), and on a tailnet the tailnet *is* the auth perimeter. The one listener
  that carries a PIN is `-lan`, off by default; a client pointed at one gets a 401 and
  the surface stays dark.
- **`seq` + `epoch` are what make a closed panel cheap.** kunai sequences every frame
  within a session and keeps a ring buffer, so reattaching asks for everything after
  the last sequence seen (`?since=N`) instead of replaying the conversation. `epoch`
  identifies the *process* behind a session id and changes on respawn — and the
  replacement numbers its events from 1 again, so a retained high-water mark would
  swallow the entire new conversation as already-seen. `KunaiEventStream` emits
  `.reset` on an epoch change and the controller drops everything it holds.
- **The panel is the question, not a list.** `NotchAgentPanel` puts the ask itself on
  the band, answerable in place, with the other sessions reduced underneath to a dot,
  a name and a status (`NotchAgentSessionsRow`). An earlier design gave three equal
  rounded cards to three unequal things — one was a question and two were status — and
  read as a dropdown menu rather than a notch surface.
- **An approval reuses `NotchApprovalBanner`'s shape exactly** (`NotchAgentAskBanner`:
  same Once / Always / No, same capsule fills, same `textGivesWayToTrailing` because
  the payload is a model-composed command of unbounded length). A permission from
  Claude Code is the same question a connector write already asks, so it is the same
  object. **A choice is not** (`NotchAgentChoiceCard`, the `AskUserQuestion` tool):
  its options are model-authored sentences, so they stack, and a multi-select needs a
  confirm. **Options are never truncated** — shortening the text of something a person
  is choosing between is the same failure as abbreviating a consent payload — so a
  card that can't render them honestly defers to kunai instead.
- **⚠️ The band's height is decided before the card lays out**, so
  `NotchAgentChoiceCard.Metrics` is pinned to explicit frames *and* read by
  `NotchAgentPanel.thickness`; `NotchAgentPanel.maxThickness` feeds
  `NotchSurfaceLayout.maxBandThickness` because the panel is sized once at window
  creation and a band taller than its panel is clipped by its own window (the width-axis
  twin of `maxStateLabelWing`). When those two disagreed, the context row under the
  choice card was cut in half. `NotchAgentPanelTests` is the lock.
- **The finished turn puts the ANSWER in display type, not the question**
  (`NotchAgentReplyExpanded`). This surface was redesigned five times and every earlier
  version made the question the headline with the reply hung underneath, which is
  backwards: you already know what you asked. The reply's **opening paragraph is the
  verdict**, set at 27pt; the question shrinks to one ember line above it; the run
  falls to a single dimmed index line at the foot. `AgentReplyDocument.split()` is
  where that reading lives, and it is pure and testable rather than a rule buried in
  the view.
  - **Words on the left, data on the right.** Below the verdict the blocks split by
    *kind* — prose into a reading column, code and tables into a column beside it,
    because those are scanned in columns and shatter when wrapped to a measure. Either
    side takes the full measure when the other is empty. **A heading travels with what
    it heads** (`split()`'s one-block lookahead): splitting purely by kind stranded
    "Toolchain" and "Worktrees" in the words column while the table and fence they
    captioned sat in the other one.
  - **The band opens as much as it needs** — `Layout.readingWidth` (860) for a
    prose-only reply, `Layout.consoleWidth` (1120) only when there is a grid to put
    beside it. One fixed width meant a two-sentence answer was laid out across a
    thousand points, which is a slab however well it is styled. `panelSize` is sized
    for the console, since the panel is created once and a band wider than its panel is
    clipped by its own window.
  - **Both columns scroll rather than clip** past `bodyCap` (0.55 of the display,
    floored), and **`bodyHeight` is the taller of the two, capped**, so a one-line
    answer still gets a one-line band. **The snapshot render clips too** — a headless
    render that lets an over-long column draw through the foot rule hides exactly the
    overflow it exists to catch.
  - **Prose is measured narrower and taller than it is set** (`proseMeasureSlack`,
    `proseHeightSlack`). `boundingRect` sees one plain regular face while the renderer
    sets inline markdown — bold runs and `code` runs in mono, both wider — and SwiftUI's
    line box is looser than the `NSFont` metrics. Under-measuring is the one error that
    shows: the column clips a sentence in half.
  - **`Theme.Notch.output` is green, deliberately not the signal teal.** Command output
    and test results are read as *terminal* output, and the app's machine accent reads
    aqua there. Scoped to this surface; every other band still wears `success`.
  - **Copy is the foot's one non-navigational action**, and it copies `lastReplyRaw`
    (the markdown), not the presented line. A turn deliberately skips `appendHistory`,
    so the band is the only place the answer exists — without this the sole way to keep
    it is a trip to the browser.
- **The other sessions get one line, once — never a notification centre**
  (`AgentAttention`, `NotchAgentNudgeBanner`). The band watches one session, so a
  second agent could block on a permission nobody would ever be asked about, or
  finish unseen. kunai's poll already reports every session's state, so the
  transitions are read from it and **no second socket exists**. The whole design is
  the restraint: the watched session is never announced (its own surfaces already
  speak for it); **only transitions**, so a session already blocked at launch is not
  news; **once per event**, remembered until the session leaves that state, so a
  flapping poll cannot repeat itself; and the **newest event wins** rather than
  queueing, because a queue on this surface is a stack of bands waiting to take the
  menu bar. A permission outranks a finish — one is a stopped machine, the other is
  only news.
  - **It is a pointer, not the card.** With one socket we do not *have* the other
    session's question, and rendering a guess at it would be worse than silence. Tap
    → `focus(sessionID:)` moves the one socket there and the real card follows. The
    tap is the consent; nothing ever yanks you to another agent on its own.
  - It sits near the **bottom** of the ladder, below everything carrying consent, a
    schedule, or unrecoverable text, and is suppressed entirely while dictating. Its
    clock is **paused while the band is busy** and it is **dropped once shown**
    (`AppDelegate.reconcileAgentNudge`), so a message can neither expire unseen nor
    reappear stale — the same paused-clock shape `dueReminderAt` uses.
  - **The tray is the agents' entry point that is not a shortcut.** The glance opens
    with a user-chosen key that is *off by default*, so a fresh install had no way to
    reach the sessions at all. A **Coding Agents** submenu lists them (click one →
    the same `focus`), hidden entirely when kunai is not running. The status icon
    reflects exactly one agent state — **another session is blocked** — because an
    icon that changed on every tool call is noise; a running count goes in the header
    line only. Both are change-guarded (`renderedAgentRows` compares *state*, not the
    elapsed label, or the menu rebuilds twice a second forever).
- **Auto mode trades the approval card for the turn undo, and that is only honest
  because kunai snapshots the working tree before every turn.** `AgentModeControl`
  offers Ask / Auto / Plan beside the question, because the moment someone wants to
  stop being asked is the moment they are being asked. **`bypassPermissions` is
  deliberately not offered**: it would trade the card for nothing, and it can't be
  undone from the same panel that set it. Ask stays the default; an unrecognised wire
  value falls back to Ask, never to Auto.
- **"What changed" and "what undo would change" are two different questions**
  (`AgentChangeSet`). The first comes from the turn's own tool calls and is short and
  readable; the second comes from `GET /api/sessions/{id}/revert`, which asks **git**,
  because a revert is a whole-repository operation that also discards later turns'
  edits and every untracked file. kunai's own comment is the reason: a list built from
  the turn's tool calls "would be reassuringly short and wrong". The undo summary
  leads with the deletion count, since restoring a tracked file is recoverable and
  deleting an untracked one is not.
- **The ask sits directly below the connector approval card in the band ladder** and
  above everything else. Both are consent with a caller suspended behind them; the
  connector card wins because it denies itself on a timeout, so it is the one that must
  not wait. `AppState.shouldShowAgentAsk` is the single test the ladder, the panel
  interactivity (`setInteractive`) and `notchIsOccupied` all read.
- The controller **starts dormant** (`AppState.agents`, started from
  `proceedAfterAuthIfNeeded` with the rest of the post-gate bring-up) so `swift test`
  and the headless snapshot renderer never open a socket or poll a port — the same
  posture as `UsageStore(load: false)`. Polling is 3s, deliberately far slower than the
  0.5s UI tick, because it is a network call whose answer changes on human timescales.
- **One key, user-chosen, and it is the only new binding** (`AppState.agentHotkey`,
  `WhisperMaster.agentHotkey.v1`). **Hold it and talk** → the words go to a coding
  agent instead of being typed; **tap it** → the glance opens (tap again to close).
  Two gestures on one key rather than a shortcut per surface, the same trade the
  push-to-talk key already makes with hold / double-tap / toggle. A tap is resolved on
  the *release* (`agentTapMaxHold`, 0.35s) rather than by delaying the start, because
  starting on the press is what keeps the first word of a real dictation.
  **Off by default**: reserving a modifier on every Mac for a server almost nobody
  runs is exactly the quiet imposition the fn-claim rules exist to prevent. A key that
  collides with push-to-talk resolves to nil (`effectiveAgentHotkey`) and the monitor
  comes down — dictation wins, and Settings says so rather than leaving a picker that
  silently does nothing.
- **A spoken prompt always lands somewhere.** `deliver(prompt:startingIn:)` attaches to
  the target session and sends; with no session at all it **creates one**
  (`POST /api/sessions`, mode set *at create* because the CLI applies it as a spawn
  flag and sent later it arrives too late to govern the first tool call). Where it
  cannot — no server, or nothing running and no folder configured — the words go to the
  **undelivered banner** with its Copy button. They are never pasted into whatever app
  is in front: the user held a key that means "send this to the agent", and typing it
  into their editor is the one outcome that key press ruled out. The new-session
  directory is `agentDefaultDirectory`, falling back to a directory kunai already
  reported; deliberately **not** the home directory, because starting an agent loose in
  `~` is a bad afternoon.
- **The band names the destination while you hold the key** ("Dictating to
  whisper-master"), through `NotchActivity.label(agentTarget:)` and the existing
  wing-growing `wideWing(forStateLabel:)`. Not knowing where your words went until
  after you let go is the whole risk of a key that redirects them.
- **Verifying against a real server:** `KUNAI_LIVE=1 swift test --filter KunaiLiveTests`
  is a bench in the style of `AudioReplayTests` — it talks to whatever kunai is actually
  installed and **skips rather than fails** when there is none, so CI and a fresh clone
  stay green. Snapshots: `pill-10-agent-run`, `pill-10b-agent-choice`.

### Diagnostics (local-only, `DIAGNOSTICS` build)

A developer-only session tracer, **compiled out of every shipped build**. Gated behind the `DIAGNOSTICS` compile flag: **`DIAGNOSTICS=1 bash Scripts/install.sh`** builds a **Release-optimized** app (so latency/RTF numbers are real) with the tracer on; CI never sets the flag, so `Diagnostics.shared` is a `NoopDiagnostics` and no session data or audio is ever written on a tester's machine. Spec: `docs/superpowers/specs/2026-07-09-diagnostics-session-tracing-design.md`. Each dictation writes a `SessionTrace` to `~/Library/Application Support/WhisperMaster/Diagnostics/` (pretty JSON + a mono WAV of the captured audio + an `index.ndjson` summary; newest 100 kept): a latency **timeline** (key-down → notch → engine → mic warmup → first partial/confirmed → each deterministic stage → paste), **audio** stats (device, is-Bluetooth, sample rate, RMS/peak/clip), the **raw-ASR → per-stage → final** text chain, the **target app** + focus AX snapshot + paste outcome, and the live **LLM verdict** (`llmReady`/`llmRaw`/`llmAccepted`/`llmMs`, captured on the beforePaste path — distinguishes "model no-op" vs "guard rejected" vs "not ready"). This is the instrument for diagnosing field reports ("it misses words / mic feels bad / it's slow") from real recordings instead of guesses; `Scripts/diag-to-cases.swift` turns saved sessions into an audio `cases.jsonl` for the eval/replay harness. Modular under `Diagnostics/` (`SessionTrace`, `AudioSignalStats`, `SessionAudioWriter`, `DiagnosticsStore`, `DiagnosticsRecorder`, `Diagnostics` facade; pure units unit-tested in `DiagnosticsTests`). The facade no-ops without the flag, so call sites in `DictationViewModel`/capture carry no `#if`.

### UI iteration — headless snapshots (Debug-only)

A fast loop that replaces the slow build → sign → install → relaunch cycle for UI work, **compiled out of Release** (CI builds `-configuration Release`). `WM_SNAPSHOT=<dir> .build/debug/WhisperMaster` renders every settings panel + onboarding step to PNGs via `ImageRenderer` and exits — no window, no install (`App/SnapshotMode.swift`, checked first in `AppMain`). This is how to *see* a UI change without the running app. `ImageRenderer` can't draw AppKit controls (`TextEditor`, `TextField`, the hotkey `Menu`), so those read `@Environment(\.isSnapshot)` (set true during a render) and substitute a static SwiftUI stand-in — keep that in sync when adding an NSView-backed control (e.g. `VocabularyEditor`'s add field). Mock data is seeded in `SnapshotMode.seedMockData`.

### Hotkey

`HotkeyManager` watches `NSEvent.flagsChanged` (both local + global monitors) to detect modifier-key press/release for push-to-talk. Each `HotkeyOption` carries its own `keyCode` and `modifierBit`. **The default is the Globe/`fn` key** (keyCode 63, `NX_SECONDARYFNMASK` `0x800000`) — the one modifier on a MacBook that isn't already spoken for by a shortcut you'd type mid-sentence.

**There is exactly one push-to-talk key** (`WhisperMaster.hotkey.v1`, plus `WhisperMaster.holdToTalk.v1`), loaded in `AppState.init`. It's persisted — it wasn't before, so a changed key silently reverted to the default on the next launch and read as "changing the key doesn't work". A **second** key, the dedicated "ask about my day" push-to-talk (`WhisperMaster.dayQueryHotkey.v1`, default right ⌘, its own `HotkeyManager`, its own Settings picker, and `AppState.firstHotkey(excluding:)` to keep the two off the same physical key), was **retired**: the assistant is the fn+control chord, and a second key reaching a strict subset of what the chord does was one entry point too many. The defaults key is left on disk, never read — don't reuse the name.

**⚠️ Holding the push-to-talk key dictates and does nothing else — no path may infer intent from the words.** Everything else — every agent action, every connector conversation — is behind the fn+control chord, and that separation is a safety property, not a UX preference. The assistant path **suppresses the paste**, so any rule that guesses "this dictation was really a question" eats the transcript whenever it guesses wrong. Two such rules have now been removed for exactly this reason: `voiceCommandsEnabled`, which inspected every dictation for a leading "remind me…", and `DayQueryDetector.matches` running over every finished transcript (gated only on having a readable calendar), which routed "what's my schedule for the sprint?" into the calendar agent and answered a question nobody asked. Neither is coming back. `DayQueryDetector` still exists and still runs — but *only* inside `routeCommandCapture`, downstream of the chord, where the paste has already been ruled out and the worst case is a wrong-shaped answer instead of a lost transcript.

**One key, three gestures** — recognised by `HotkeyGesture` (pure, clock-injected, `HotkeyGestureTests`), which `HotkeyManager` drives with `NSEvent.timestamp` plus a `Timer` for the deferred stop:
- **hold** → `.start` on the key-down, `.stop` on the release. `.start` fires on the *press*, never after a wait-and-see delay — first-word latency is the thing this app protects.
- **double-tap** → `.handsFree`: the recording that the first tap already started keeps running with the key released (`AppState.handsFreeActive`, transient). The notch says so — `DictationStatusView.keyIsHoldingItOpen` feeds `NotchActivity.label`, which reads "Dictating (hands-free)" whenever the key isn't what's holding the band open.
- **double-tap again** → `.stop` (as does a deliberate hold, an escape hatch for a missed second tap).

The one cost: a lone quick tap can't be resolved at its release, since a second tap right after would have made it a latch — so a tap's stop is **deferred** by `doubleTapWindow` (0.4s) and resolved by `flush`. That only ever extends a sub-`tapMaxHold` (0.35s) recording by a fraction of a second, capturing a few more trailing frames rather than losing any. `stopRecording` calls `hotkeyGestureReset()` so a latch can never outlive the session it latched (a stop from the tray would otherwise leave the next tap reading as "stop"). Toggle mode (`holdToTalkEnabled` off) bypasses the recogniser entirely — `HotkeyManager` reads the preference through a `holdToTalk` closure and emits `.toggle` on each press. That path was **dead before this** (the view model's handlers `guard state.holdToTalkEnabled else { return }`-ed, so toggle mode did nothing at all).

**The assistant is a held chord, not a setting (`ModifierChordMonitor`).** Holding **fn + control** while you speak sends the transcript to the assistant instead of typing it — and this is the **single entry point** for all of it: notes and reminders ("take a note that…", "remind me to call mom tomorrow"), calendar and connector reads ("what's on my calendar?"), connector writes (which raise the approval card), all through one held chord. Nothing else reaches the agent. Three things about it are load-bearing:
- **A chord can't be recognised the `HotkeyManager` way** (match the key code that changed, read that key's own bit): either half can be the key that moved, and the other half only shows up in the event's full modifier mask. So `ModifierChord.isHeld` tests the whole mask, using the *generic* `.function`/`.control` flags rather than the device-dependent left/right bits — which makes it side-agnostic for free.
- **The chord *arms* a session; it doesn't necessarily start one.** It shares the fn key with the default push-to-talk, so pressing fn a hair before control has already begun an ordinary dictation. `handleCommandChordEngaged` therefore re-labels a session already in flight (`setCommandArmed`) and only *starts* one when nothing is running — the two presses are never simultaneous, and a restart would drop the first word. `commandChordOwnsSession` records which case it was, so releasing control stops the recording only when the chord is what opened it; otherwise the push-to-talk key still owns the stop.
- **An armed capture is never pasted, and it always lands somewhere.** `routeCommandCapture` runs three tiers in order, and each later one exists to guarantee the earlier can't lose the words. The notch says `Asking the assistant` while the chord is held, and while the loop runs it **names the connector it's waiting on** — `Checking Personal`, `Adding to Personal`, `Posting to #ops` — falling back to `Working on it` before the first tool call and for any tool the copy doesn't recognise (`AppState.commandCaptureArmed` / `commandAgentRunning` / `agentActivity` → `NotchActivity.label`; `AgentLoop.onStep` → `AgentActivity`). Where the words went is otherwise invisible until the banner, after the fact, and a 30-second budget spent under one static caption can't distinguish a calendar read from a Slack post or from a connector that has stalled. `requestCalendarAccessIfNeeded()` runs first, so the tools the agent is about to reach for aren't refused on a permission nobody was ever prompted for. `requestCalendarAccessIfNeeded()` runs first, so the tools the agent is about to reach for aren't refused on a permission nobody was ever prompted for.
  - **The agent** (`CommandAgentService`, tried whenever the on-device model is loaded) — an `AgentLoop` over `LocalToolCatalog` (`create_note`, `create_reminder`, `list_reminders`) plus the connector tools when `connectorAgentEnabled` is on. So the chord can file a reminder whose time is buried mid-sentence, read the calendar, or run a connector write — none of which a keyword gate could reach. Times come back as the **phrase the user spoke** and are read by `RelativeTimeParser`; a 3B asked for ISO-8601 invents plausible, wrong dates.
  - **The deterministic day summary** — `DayQueryDetector.matches` + `DaySummaryService.buildAsync`, for a capture that reads as a question about the day when the agent couldn't take it. No model, so "what's on my calendar" still answers on a cold start or on a Mac that never downloaded the 1.5 GB LLM. This is the *only* legal call site for `DayQueryDetector` (see the prohibition above).
  - **The deterministic gate** — the original keyword path (`CommandDetector` picks note-vs-reminder and strips the trigger phrase; no trigger at all becomes a **note**, the kind that needs nothing but words). Used whenever nothing above took it.
- **"Answered without any tool having executed" counts as not acting**, and that rule is the safety property the whole path hangs on: the paste is suppressed, so a model that talks instead of acting has thrown the user's words away. `CommandAgentService` returns nil there and the fallback files them. It is about **execution, not attempt** — a call rejected as malformed also leaves `executed` empty, and an answer written on top of a refusal is the model reporting data it never received. **Do not relax it to "no tool call means it was just chatting"**; `CommandAgentTests.testAnAnswerWithNoToolCallIsNotAccepted` and `testConnectorToolsAreWithheldUntilTheAssistantIsOptedIn` both catch that, and both are right. Conversation through the chord comes from its *tools*, not from letting a 3B improvise. The mirror case is handled too — a loop that runs dry *after* creating something reports the tool's own result rather than falling through, which would file the same words twice and caption it "Note saved".
- **Creations and answers get different surfaces.** A creation is already durable in Notes & Reminders, so the band is a receipt: `showCommandConfirmation`, a checkmark to glance at. An **answer** exists only as long as the band does, so it goes through `presentAnswer` — `activeDaySummary` (whose clock the AppDelegate refresh loop pins while the voice runs, which the confirmation band's does **not**), `appendAnswer` so it stays readable in Today → Recent answers, and `speakAnswer`. One function, so every answer lands the same way whatever produced it.
  - **`ToolAccess.local` is not `.write`.** A write is a call to somebody else's service, which is what the approval card gates; a note is the user's own on-device data, and the chord *is* the consent. `CommandToolRouter` runs local tools itself and never lets one reach `ToolRouter` (which fails plainly if one does).

There is **no toggle** behind the chord and there must not be one (`connectorAgentEnabled` gates only whether the *connector* tools join the tool set — notes and reminders are always reachable, and the deterministic day summary needs only `hasReadableCalendar`, so a calendar question answers with the assistant toggle off): the old opt-in `voiceCommandsEnabled` ("Create by voice") inspected *every* dictation for a leading "remind me…" and was removed with its defaults key — an unarmed dictation is plain text again, whatever it opens with. The chord is fixed rather than user-configurable, and dormant where `FeatureFlags.connectorsAndNotesAvailable` is false (stable), since arming a session we'd have to un-arm at the end would promise the notch a note and then paste the words.

**The app claims the Globe key when it's the push-to-talk key, once, and says so.** `AppDelegate.claimFnKeyIfChosen` calls `FnKeyBehavior.claimFnKeyForPushToTalk()` from `proceedAfterAuthIfNeeded` (post-sign-in, **not** `setupHotkey` — this writes a system-wide preference, and doing that to someone who has only seen the sign-in gate would be changing their Mac before they decided to use the app) and again whenever the hotkey changes to fn. The collision it removes is worst on the **hands-free double-tap**: with the stock "Press 🌐 key to: Show Emoji", latching hands-free opened and closed the emoji picker on the way, stealing focus from the very app the dictation was aimed at. Three rules keep it from being an app overruling a person about their own keyboard: it only fires when the user has **already chosen fn** (that choice is the consent — asking per-tap is the wrong shape); it happens **exactly once**, recording the claim and the prior value under `WhisperMaster.fnUsage.claimed.v1` / `.previous.v1`, so someone who puts the emoji picker back keeps it; and Recording settings shows a **settled note naming what was turned off** with a one-click `restoreSystemFnBehavior()` beside it, because changing a system-wide preference silently would be the wrong kind of helpful. If the write doesn't take (macOS holds the old value until logout), `conflictsWithPushToTalk` is still true and the existing warning hint takes over — the claim never *claims* success it can't verify.

**We observe the fn key, we don't consume it — so the system setting is the fix.** The monitors are passive, so whatever macOS binds to Globe (emoji picker, input-source switch, its own dictation on a double-press) still fires alongside us. Swallowing it would need a HID-level `CGEventTap` that also breaks fn+F-key and fn+arrow, which isn't worth it. So `FnKeyBehavior` goes at the preference instead: it **reads and writes** `AppleFnUsageType` in `NSGlobalDomain` through `CFPreferences`/`kCFPreferencesAnyApplication` (not `UserDefaults.standard` — standard *reads* fall through to the global domain but standard *writes* land in our own app domain, where nothing looks for them). When the value isn't "Do Nothing", the Recording settings show a hint with **two** buttons: **"Turn it off"** (`stopSystemFromUsingFnKey()`, one tap, needs the app to stay un-sandboxed) and the old trip to the Keyboard pane. The write can't confirm itself — `CFPreferencesSynchronize` reports the flush, not whether the input-method agent picked the value up — so the function re-reads `current` and returns what it actually sees, and the hint says "log out and back in" rather than claiming success. Treat an *absent* key as a conflict: no Mac with a Globe key defaults to doing nothing, which is why the **hands-free double-tap fired the emoji picker twice** on a fresh machine. `showsFnConflictHint` reads `CFPreferences`, which SwiftUI can't observe, so it touches a `fnConflictToken` `@State` that the button bumps — without that the hint never clears after its own fix.

## Conventions to keep

- `@MainActor` annotation on classes that touch UI/AppKit; never call them off the main actor.
- `Sendable` on the transcriber protocol — buffer/update closures cross actor boundaries.
- The view model is the ONLY thing that mutates `PrototypeAppState`. Views read; AppDelegate polls; nothing else writes.
- Don't introduce a second status item or second settings window; the AppDelegate's single-instance ownership is load-bearing.
