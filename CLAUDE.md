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

**Text-processing rules that constrain this pipeline** — custom vocabulary as
post-processing (never engine biasing), the ITN rule against summing digit
sequences, and deterministic self-correction collapsing — live in
`Sources/WhisperMaster/Transcription/CLAUDE.md`, next to the code they govern.
Cover any change with `DeterministicITNTests` / `SelfCorrectionCollapserTests`,
and validate it against the audio bench above before shipping.

### Evaluation engine (`eval/text-cleanup/`)

A quality-first eval for the cleanup pipeline: durable logic in Swift, disposable
glue in shell, Claude Code as the judge, with run history on a public dashboard.
Full details: **`.claude/skills/eval-pipeline/SKILL.md`**. Verify any change to the
cleanup pipeline against the real thing via `eval/text-cleanup/run-eval.sh`.

### Assistant tool-calling bench (`WM_AGENT_TOOL_EVAL`)

The eval above scores *cleanup*. The chord's tool calling has its own bench,
`App/AgentToolEval.swift` — sixteen spoken commands with the tool each one should
call, run through three generation paths on the real Qwen3-4B, plus one turn that
reads a 460-word tool result (the case where the paths separate).

```bash
CONFIG=Debug SIGN_IDENTITY=- bash Scripts/bundle.sh
WM_AGENT_TOOL_EVAL=1 "./build/Whisper Master.app/Contents/MacOS/WhisperMaster"
```

**It must be the app bundle, not `.build/debug/WhisperMaster`.** The SwiftPM binary
dies with `Failed to load the default metallib` — MLX's Metal shaders are a bundle
resource only `xcodebuild` stages. The bench needs the **assistant** model
(`Qwen3-4B-Instruct-2507-4bit`, ~2.3 GB) installed under
`~/Library/Application Support/FluidAudio/Models/`; without it the bench prints
`ABORT` and exits, so it is safe to run anywhere. To install it outside the app,
fetch `$(ModelInstaller.mirrorBaseURL)/Qwen3-4B-Instruct-2507-4bit.zip`, check the
digest against `ModelChecksums.sha256`, and unzip it into that directory.

The three arms are `via clean` (the retired routing, kept as the control),
`hand-rolled` (what ships) and `native` (the chat template's own tools mechanism,
built and tested but **not** wired into production — nothing sets
`AgentLoop.generateNative`).

**Measured 2026-08-22.** All three call the correct tool 16/16 on the first turn,
so first-turn tool choice is not what separates them — **don't re-run the bench to
decide that question again.** They separate on the turn that reads a result:

- `via clean` answered from **part of the data and said nothing about it**. The
  460-word conversation is past the chunk budget, so it was split, each piece
  generated separately and joined — and the parser then took the first balanced
  JSON object and dropped the rest. Both runs reported only the work calendar and
  gave its range as 01:00–07:00 when the data says 01:00–09:00. This is the failure
  the cleanup routing actually caused: not a crash, a confident wrong answer.
- `hand-rolled` and `native` both answered correctly across both calendars.
- **Native is not better here, so it stays unwired.** It matched the hand-rolled
  path on tool choice and grounding, and its answer ran longer. Flipping the
  default needs a case the bench can show, not the argument that the chat template
  is more in-distribution.

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
  and `hotfix/*`, and every production release is tagged `vX.Y.Z` (CI pushes the
  tag; don't add a second one by hand). Nothing on the server enforces this: the
  repo is private on a free plan, so branch protection and rulesets are
  unavailable. Feature branches are `feature/<slug>` off `dev` — no ticket id —
  and **a branch is deleted in the same step it is merged**.
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

The app is **gated behind Clerk sign-in at launch**: dictation won't start until a
user is authenticated. Transcription itself still runs entirely on-device — only
the *gate* talks to Clerk's cloud. Details (config, gate window, the OAuth
redirect allowlist each build needs, the bridging timer, enforcement points):
**`Sources/WhisperMaster/Auth/CLAUDE.md`**.

### State (`PrototypeAppState`)

Single `@Observable` source of truth, `@MainActor`-bound. The view model mutates it; SwiftUI views observe it; AppDelegate's tray refresher polls it. Includes:

- `phase: PrototypePhase` (idle/preparingModels/recording/stopping/failed)
- Engine selection state — `selectedEngine`, `preparedEngine`, `preparingEngine` are three distinct slots (do not collapse them; the UI distinguishes "user has chosen X" from "X is currently being downloaded" from "X is ready to use").
- `history: [TranscriptHistoryEntry]` — persisted in `UserDefaults` under `WhisperMaster.transcriptHistory.v1`, capped at 50 entries (newest first). `appendHistory` is the only entry point; bypassing it skips persistence. It still backs the **tray's** recent-transcripts submenu (paste-it-again), which is all it is for now that the History *page* is gone — see Traces below.
- `traces: TraceStore` — what actually happened to the last 40 dictations and assistant captures. Written only from the view model, like `usageStore`.

### Traces (`Traces/`, `TracesSettingsView`)

The page where "why did it do that" is answerable: a **Dictation** tab (raw ASR →
each pass → the polish verdict → where the words were delivered) and an
**Assistant** tab (which tier took the words *and why the others didn't*, the tools
the model was offered, and every connector call). It **replaced the History page**,
which listed final transcripts — the least interesting artifact of the run, and
already sitting in the app you dictated into. Details:
**`Sources/WhisperMaster/Traces/CLAUDE.md`**.

### Usage & Insights (`Usage/`, `InsightsSettingsView`)

The Insights tab is a real analytics dashboard, not mock data — computed live from
recorded dictations, **per-account rather than device-wide**, with best-effort
opt-out cloud sync. Details: **`Sources/WhisperMaster/Usage/CLAUDE.md`**.

### Transcription engine (`Transcription/`)

One engine (`slidingWindow`, NVIDIA Parakeet) behind
`FluidAudioStreamingTranscriber` — a **single** window track, with no live
preview of it on the notch — plus the opt-in on-device MLX qwen cleanup and the
mirror-first model install. Details:
**`Sources/WhisperMaster/Transcription/CLAUDE.md`**.

**⚠️ Three prohibitions from that file hold everywhere:** don't re-enable
`configureVocabularyBoosting` "to improve accuracy" — FluidAudio's streaming CTC
vocabulary rescorer corrupts transcripts, so custom vocabulary is post-processing;
don't let a run of bare unit words fall through to `SpokenNumber.value`'s additive
sum ("one two three" is a spoken sequence, not 6); and don't lower the track's
`chunkSeconds` to put live words on the notch sooner — `finish()` reconstructs
the text that actually gets pasted from those same windows. The second
short-window "preview" manager that used to paint the notch was **removed on
purpose**; don't reintroduce it.


### Reading answers aloud (`Speech/`)

An assistant answer is spoken as well as shown; a dictation is never read back.
**`Speech/` is playback and must stay separate from `Audio/`**, which is the
capture graph — nothing under `Speech/` touches `AVAudioEngine` or a Core Audio
HAL property, and that is what makes it safe to run beside
`MicrophoneCaptureService`. Silence is never an outcome: any failure falls back to
the system voice. Details: **`Sources/WhisperMaster/Speech/CLAUDE.md`**.

### Recording lifecycle (`Audio/`, `PrototypeViewModel`)

`startRecording` → `prepareSelectedEngineIfNeeded` → `transcriber.start` →
`microphoneCapture.start`, with a per-buffer `Task` so the tap never blocks and a
deliberate `releaseTailNanoseconds` flush on stop — don't remove it. Details
(Bluetooth "call mode", `AVAudioEngineConfigurationChange` recovery and its two
loop guards, mic warm-start): **`Sources/WhisperMaster/Audio/CLAUDE.md`**.

### Pausing what is already playing (`Media/`)

The microphone hears the speakers, so dictating over a podcast transcribes the
podcast too. Music and video on this Mac are paused from the key press and
released once the whole exchange is over — including an answer read aloud. On by
default (`AppState.pauseMediaWhileListening`). Details:
**`Sources/WhisperMaster/Media/CLAUDE.md`**.

Saying "pause the music" or "next song" **through the assistant chord** does it
directly, ahead of the model — and takes the wheel, so the automatic hold does not
re-pause what the user just started.

**⚠️ Three rules from that file hold everywhere.** The play/pause key is a *toggle*
sent to whichever app macOS calls "now playing", so pressing it blind can **start**
music rather than stop it — `MediaPlaybackPolicy` is therefore an allowlist of apps
known to answer the key, and must never be inverted into a blocklist. **Exactly two
presses leave per hold, one down and one up, and nothing may press in between**: a
player holds its audio stream open after it stops (~3.5 s for Music, far longer for a
browser), so any mid-hold press acts on a guess, and both bugs this feature shipped
were that press — one oscillated the music for as long as the key was held, the other
undid a *correct* pause a few seconds into every dictation. A press that went the
wrong way is corrected by the release press, which has to happen anyway. And reading
the Core Audio process list is **not** the device juggling prohibited below: it sets
no HAL property and names no device, and it always runs off the main actor.

**⚠️ Do NOT add code that programmatically juggles audio devices** to "auto-fix"
Bluetooth or input routing. It was tried three times (0.3.5–0.3.6) and every
variant broke something, up to hanging in Core Audio with the app unresponsive.
The capture path sets no HAL property. Rebuilding our *own* `AVAudioEngine` object
on a configuration change is a different thing and is allowed; the user-initiated,
off-main `switchToBuiltInMic()` behind the notch banner is the one sanctioned
device write. The full account is in the file above.

### Notes: the recording is part of the note (`Notes/`)

A note made by voice keeps **three** things: the assistant's tidied `title`/`body`,
the verbatim `transcript`, and the `audio` of the dictation that produced it —
"did it hear me right?" is the first question a spoken note raises. Details (the
always-on audio tee, both creation paths, why audio isn't synced):
**`Sources/WhisperMaster/Notes/CLAUDE.md`**; UI in
`Sources/WhisperMaster/UI/CLAUDE.md`.

**⚠️ `Note`'s `Codable` conformance is hand-written and must stay that way.**
Notes are already on disk from before pinning, transcripts and audio existed, and
`NotesStore.loadFromDisk` swallows a decode throw — so a bare non-optional field
added here silently empties every existing user's notes. Every field added from
here on uses `decodeIfPresent` with a default.

### Gentle reminders (`Reminders/`)

Idle nudges and user-set reminders both surface in the notch band — **not** in
Notification Centre, which is Sparkle's update reminder alone. Details (the
policy / bookkeeping / copy / scheduler split, active-vs-completed queries, and
the two-way checkboxes with snapshot-based undo):
**`Sources/WhisperMaster/Reminders/CLAUDE.md`**.

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

Opt-in (on by default, one-tap opt-out in Settings) product analytics fanned out to
PostHog and GA4 behind a single vendor seam, plus PostHog crash capture and a
deliberately redundant next-launch crash counter. Details:
**`Sources/WhisperMaster/Analytics/CLAUDE.md`**.

**⚠️ Two rules hold outside that file.** The *events* stay content-free and
account-free — identity lives on the person profile alone, and
`AnalyticsTaxonomyTests.testNoEventParameterCarriesAccountIdentity` is the lock, so
an exported event stream is not a customer list. And the Settings copy says
**"Share usage data"**, never "anonymous"; it moves together with the landing
page's `lib/legal.ts` flow and privacy retention paragraph.

### UI

Theme/design-system and notch-surface rules live next to the code they govern:
**`Sources/WhisperMaster/UI/CLAUDE.md`** (loaded when you work under `UI/`). New UI
uses `Theme.swift` tokens and the `UI/Components/` ladder, never ad-hoc literals.

### The brand mark (`Scripts/make-logo.swift`)

The mark **is the orb** — the dotted sphere the notch draws while listening,
frozen on one frame. One generator writes every surface, so the app and the
landing page cannot drift:

```bash
swift Scripts/make-logo.swift    # from the repo root
# → Resources/AppIcon.icns, Sources/.../WhisperMasterLogo{,Small,Medium}.png,
#   WhisperMasterTrayGlyph.png, and (if the landing page is checked out beside
#   this repo, or WEB_DIR is set) its favicon.ico / apple-icon.png / wordmark mark
```

**⚠️ A dot field cannot be downscaled, and this is the bug it causes.** Every
size is *drawn* at its own density; nothing is resampled. `BrandLogo` used to
hand SwiftUI the 1024 tile and `.resizable()` it into 34pt — ~450 dots into 34
points — and the logo rendered as a brown smudge. So reach for the mark through
**`BrandLogo(size:)`**, which picks the tile drawn for that box via
`BrandAsset.appTile(points:)`, and never load a logo PNG directly. A call site at
a size the ladder doesn't serve gets a tile laid out for a different box: muddy,
not broken, so nothing will fail to tell you. Add the tier in both places
(`appTile` and the script's `appTiles`).

**⚠️ The wave painter in the script is a deliberate frozen copy** of the one in
`UI/ThinkingOrb.swift`, not a shared import — a logo must not change shape
because somebody retuned an animation. If you re-tune the engine and want the
mark to follow, port it on purpose and re-run.

### Text injection (`Input/`)

`TextInjector` (actor) synthesizes keystrokes via `CGEvent` and requires
Accessibility permission; `pasteFinal` picks its mechanism from what Accessibility
reports at the focused element, with terminals always taking the real ⌘V path.
Details (paste routing, the Chrome gap, Secure Keyboard Entry, why dev builds need
their own grant): **`Sources/WhisperMaster/Input/CLAUDE.md`**.

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
  finish unseen. The **fleet push** (`/ws/fleet`) reports every session's state, so
  the transitions are read from it rather than from a poll, and the only additional
  socket is the permissions-only one a blocked neighbour gets. The whole design is
  the restraint: the watched session is never announced (its own surfaces already
  speak for it); **only transitions**, so a session already blocked at launch is not
  news; **once per event**, remembered until the session leaves that state, so a
  flapping poll cannot repeat itself; and the **newest event wins** rather than
  queueing, because a queue on this surface is a stack of bands waiting to take the
  menu bar. A permission outranks a finish — one is a stopped machine, the other is
  only news.
  - **For a finish it is a pointer, not the card.** A finished neighbour's answer
    lives only on its own stream, and rendering a guess at it would be worse than
    silence. Tap → `focus(sessionID:)` moves there and the real thing follows. The tap
    is the consent; nothing ever yanks you to another agent on its own. A **blocked**
    neighbour is the exception the second socket buys: its question is real, carried
    on its own permissions-only stream, so the card can be answered in place — and
    `askOwner` records which socket raised it, because the answer has to go back down
    that one.
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

A developer-only session tracer, **compiled out of every shipped build** — CI never
sets the flag. Build it with `DIAGNOSTICS=1 bash Scripts/install.sh`. Details:
**`Sources/WhisperMaster/Diagnostics/CLAUDE.md`**.

### UI iteration — headless snapshots (Debug-only)

A fast loop that replaces the slow build → sign → install → relaunch cycle for UI work, **compiled out of Release** (CI builds `-configuration Release`). `WM_SNAPSHOT=<dir> .build/debug/WhisperMaster` renders every settings panel + onboarding step to PNGs via `ImageRenderer` and exits — no window, no install (`App/SnapshotMode.swift`, checked first in `AppMain`). This is how to *see* a UI change without the running app. `ImageRenderer` can't draw AppKit controls (`TextEditor`, `TextField`, the hotkey `Menu`), so those read `@Environment(\.isSnapshot)` (set true during a render) and substitute a static SwiftUI stand-in — keep that in sync when adding an NSView-backed control (e.g. `VocabularyEditor`'s add field). Mock data is seeded in `SnapshotMode.seedMockData`.

### Hotkey and the assistant chord (`Input/`)

One push-to-talk key (`WhisperMaster.hotkey.v1`, default Globe/`fn`) with three
gestures — hold, double-tap to latch hands-free, double-tap again to stop — plus
the held **fn + control** chord that is the single entry point to the assistant.
Details (`HotkeyGesture`, `ModifierChordMonitor`, `routeCommandCapture`'s three
tiers, the one-time `AppleFnUsageType` claim):
**`Sources/WhisperMaster/Input/CLAUDE.md`**.

**⚠️ Holding the push-to-talk key dictates and does nothing else — no path may
infer intent from the words.** Everything else is behind the chord, and that
separation is a safety property, not a UX preference: the assistant path
*suppresses the paste*, so any rule that guesses "this dictation was really a
question" eats the transcript whenever it guesses wrong. Two such rules —
`voiceCommandsEnabled`, and `DayQueryDetector.matches` running over every finished
transcript — were removed for exactly this reason and are not coming back.
`DayQueryDetector` is legal **only** inside `routeCommandCapture`, downstream of
the chord, where the paste has already been ruled out. **`MediaCommandDetector`
("pause the music") is under the same restriction** and matches the whole capture
rather than a word inside it — run over an ordinary dictation it would eat the
sentence and type nothing.

**⚠️ "Answered without any tool having executed" counts as not acting.** With the
paste suppressed, a model that talks instead of acting has thrown the user's words
away, so `CommandAgentService` returns nil and the deterministic fallback files
them. It is about execution, not attempt. Do not relax it to "no tool call means
it was just chatting" — `CommandAgentTests` catches that, and it is right.

There is **no toggle** behind the chord and there must not be one.

## Conventions to keep

- `@MainActor` annotation on classes that touch UI/AppKit; never call them off the main actor.
- `Sendable` on the transcriber protocol — buffer/update closures cross actor boundaries.
- The view model is the ONLY thing that mutates `PrototypeAppState`. Views read; AppDelegate polls; nothing else writes.
- Don't introduce a second status item or second settings window; the AppDelegate's single-instance ownership is load-bearing.
