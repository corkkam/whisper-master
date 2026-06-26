# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A standalone macOS menu-bar app prototype for local-first streaming dictation, built on `FluidAudio` + NVIDIA Parakeet. **Intentionally separate** from the sibling project `/Users/ninja/coding/lyzr-exprmt/lyzr-whisper` — do not cross-modify; this is the sandbox for evaluating on-device streaming ASR on Apple Silicon.

## Commands

This is an **Xcode project**, generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is the source of truth; the `.xcodeproj` is git-ignored and regenerated. `Package.swift` is kept so `swift build` still works for quick CLI compile checks, but the shippable `.app` is produced by Xcode.

```bash
# First time / after editing project.yml or adding source files
brew install xcodegen        # one-time
xcodegen generate            # (re)creates WhisperMaster.xcodeproj
open WhisperMaster.xcodeproj # work in Xcode normally

# Quick compile check (no .app bundle)
swift build

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

There is no test suite.

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

Product: `WhisperMaster.app`, bundle id `app.whispermaster.mac`, executable `WhisperMaster`; distributed as `Whisper Master.app` / `.dmg`.

### How we build

`project.yml` → `xcodegen generate` → `WhisperMaster.xcodeproj` (git-ignored) → `xcodebuild`. Day-to-day: open the `.xcodeproj` in Xcode, or `swift build` for a fast headless compile check (no `.app`). Shippable `.app`: `Scripts/bundle.sh` (xcodegen → `xcodebuild -configuration Release` → stage to `build/Whisper Master.app`).

### Signing & keys (no paid Apple account)

- **Code signing:** a self-signed keychain cert named **`whisper master`** (created in Keychain Access → Certificate Assistant → *Create a Certificate* → Self-Signed Root / Code Signing). `bundle.sh` & `release.sh` default `SIGN_IDENTITY="whisper master"`; pass `SIGN_IDENTITY=-` for ad-hoc. **Not notarized** (needs the $99 Developer Program), so each recipient runs `xattr -dr com.apple.quarantine "/Applications/Whisper Master.app"` once on first install; Sparkle's later updates don't re-trigger Gatekeeper.
- **Update signing:** a Sparkle **EdDSA** keypair (Sparkle's `bin/generate_keys`; private key lives in the login keychain, public key is `SUPublicEDKey` in `Info.plist`). Export for CI with `generate_keys -x <file>`.
- The clean future upgrade is a paid **Developer ID + notarization** for warning-free installs (would slot into `bundle.sh`/CI).

### Distribution & auto-update (Sparkle + Cloudflare R2)

- **Hosting:** R2 bucket `whisper-master`; public read URL `https://pub-033f6365404f4b37ac6c630d4feb0dcd.r2.dev`; S3 (upload) endpoint `https://db4d52dbca4f08ab7bd161955d66ed6a.r2.cloudflarestorage.com`. Credentials in `.env` (git-ignored; template `.env.example`): `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_BUCKET`, `R2_PUBLIC_BASE_URL`.
- **Layout on R2:** `appcast.xml` + `WhisperMaster-<version>.zip` at the bucket root; model archives under `models/`.
- **`release.sh`** = build+sign (`bundle.sh`) → zip → Sparkle `generate_appcast` (EdDSA-signs, sets the enclosure URL via `--download-url-prefix`) → `rclone` upload of the staged dir. It reads `.env` locally; in CI it reads the same vars from the environment and the EdDSA key from `SPARKLE_ED_PRIVATE_KEY` instead of the keychain.
- **Versioning:** bump **both** `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` before a manual release, or Sparkle won't treat it as newer.

### CI/CD (GitHub Actions)

- Repo is **private** (`HEGADE/whisper-master`); default branch `main`, active work on `dev`.
- **`.github/workflows/release.yml`** runs on **push to `dev`** (and manual `workflow_dispatch`) on a `macos-15` runner: checkout → `brew install xcodegen rclone` → import the signing cert from secrets into a temporary keychain → set `CFBundleVersion` to `github.run_number` (monotonic, so each push is "newer") → run `release.sh`. Add **`[skip release]`** to the commit message to skip a run.
- **Required repo secrets:** `SIGNING_CERT_P12_BASE64` (base64 of the cert `.p12`), `SIGNING_CERT_PASSWORD`, `SPARKLE_ED_PRIVATE_KEY`, plus the five `R2_*` values above.
- macOS runner minutes bill **~10×** — releasing on every `dev` push is intentional but costly; `[skip release]` is the cost/noise guard.

### Release flow, end to end (two ways)

A "release" = put a newer, EdDSA-signed `.zip` + an updated `appcast.xml` on R2; installed apps then self-update via Sparkle. There are two ways to trigger it:

**A. Manual (from your Mac):**
1. Bump **both** `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` (e.g. `PlistBuddy -c "Set :CFBundleShortVersionString 0.1.9" -c "Set :CFBundleVersion 11" Resources/Info.plist`).
2. `bash Scripts/release.sh` → `xcodegen generate` → `xcodebuild -configuration Release` (signed `whisper master`) → `ditto` zip → Sparkle `generate_appcast` (signs the zip with the keychain EdDSA key, writes `appcast.xml` pointing at the R2 public URL) → `rclone` uploads `appcast.xml` + `WhisperMaster-<ver>.zip` to the bucket root.
3. Verify: `curl -s "$R2_PUBLIC_BASE_URL/appcast.xml"` shows the new `sparkle:version`.

**B. CI (push to `dev`):** `git push origin dev` (commit message without `[skip release]`) → the workflow does the same as (A) on a macOS runner, but sets `CFBundleVersion` = `github.run_number` automatically (you still bump `CFBundleShortVersionString` in commits when you want a new human version). Secrets supply the cert + EdDSA key + R2 creds.

**What a tester sees:** their installed app's Sparkle polls `SUFeedURL`, sees a higher `CFBundleVersion`, downloads the signed zip, swaps the app in place, and relaunches — no reinstall. Only the **first-ever** install needs the one-time `xattr -dr com.apple.quarantine` (not notarized).

**Publishing a model to R2** (separate from app releases): from `~/Library/Application Support/FluidAudio/Models`, `ditto -c -k --keepParent <dir> <dir>.zip`, then `rclone` it to `whisper-master/models/` (creds from `.env`). Done for the engine (`parakeet-tdt-0.6b-v3`) and CTC (`parakeet-ctc-110m-coreml`) models; the app installs them mirror-first via `ModelInstaller`.

## Architecture

### Process / window model

- `LSUIElement = true` (Info.plist) → menu-bar agent, no Dock icon.
- `AppDelegate` is the single owner of all top-level objects: the status item, settings window, dictation pill window, hotkey manager, permissions manager, and a dedicated `MicrophoneCaptureService` instance for the onboarding mic test (separate from the one inside `PrototypeViewModel`, since both create their own `AVAudioEngine`).
- `applicationShouldTerminateAfterLastWindowClosed → false`: closing the settings window must NOT quit the app — the tray is the persistent surface. The `NSStatusItem` uses `autosaveName` so users can drag its position and it sticks across launches.
- A 0.5s `Timer` in `AppDelegate.startStatusRefreshLoop` polls `PrototypeAppState` and rebuilds the tray icon symbol, tooltip, header line, and history submenu. There's no `@Observable` bridge to AppKit — the timer is the bridge.

### State (`PrototypeAppState`)

Single `@Observable` source of truth, `@MainActor`-bound. The view model mutates it; SwiftUI views observe it; AppDelegate's tray refresher polls it. Includes:

- `phase: PrototypePhase` (idle/preparingModels/recording/stopping/failed)
- Engine selection state — `selectedEngine`, `preparedEngine`, `preparingEngine` are three distinct slots (do not collapse them; the UI distinguishes "user has chosen X" from "X is currently being downloaded" from "X is ready to use").
- `history: [TranscriptHistoryEntry]` — persisted in `UserDefaults` under `WhisperMaster.transcriptHistory.v1`, capped at 50 entries (newest first). `appendHistory` is the only entry point; bypassing it skips persistence.

### Transcription engine

`TranscriberEngine` has a **single case**, `slidingWindow` ("Heavy", NVIDIA Parakeet `parakeet-tdt-0.6b-v3`), implemented by `FluidAudioStreamingTranscriber` (conforms to `LocalStreamingTranscriber`, `Sendable`). An earlier "Light"/EOU streaming engine **and** an Apple Foundation Models transcript-cleanup pass were both removed — the LLM added latency without gains since Parakeet already emits punctuation/capitalization. The enum is kept (one case) for metadata + future engines. `PrototypeViewModel.transcriber` is now a single stored property. Models download on demand into `~/Library/Application Support/FluidAudio/Models/<cacheDirectoryName>`; `TranscriberEngine.isInstalled` is a filesystem check, so callers must not cache it.

**Model install is mirror-first.** `ModelInstaller` (in `ModelInstall/`, with `FileDownloader` + `Archive`) is archive-based — `installIfNeeded(archiveName:destinationRoot:label:isInstalled:onProgress:)` downloads `<archiveName>.zip` from the public R2 bucket and unpacks it into `destinationRoot`, with an accurate % (R2 returns a real `Content-Length`); on any failure it silently falls back to FluidAudio's HuggingFace download. A `TranscriberEngine` convenience overload covers the main engine (`PrototypeViewModel.installModelsFromMirror`, before `prepareModels`); the CTC vocabulary model uses the generic form. **Both the engine model and the CTC model are hosted on R2.** To publish/refresh an archive: from the models root (`~/Library/Application Support/FluidAudio/Models`), `ditto -c -k --keepParent <dir> <dir>.zip`, then upload to `whisper-master/models/` on R2 (same creds as `release.sh`).

**Custom vocabulary (biasing).** Users maintain a glossary — `PrototypeAppState.customVocabulary` (persisted under `WhisperMaster.customVocabulary.v1`), edited in the Voice-engine **"Words to get right"** field (a raw `@State` draft parsed one-way to `[String]`; don't reintroduce a normalizing two-way binding or Enter/multiline breaks). `FluidAudioStreamingTranscriber.setVocabulary` stores terms (cheap); `loadVocabularyResources` loads FluidAudio's CTC keyword model (R2-first, ~89 MB, guarded against duplicate loads) in the **background** and calls `configureVocabularyBoosting`, biasing decoding toward those terms (e.g. "RAG" not "rack"). It's warmed right after the main engine is ready (`refreshCustomVocabulary`) and re-applied after each session's manager recreation in `stop()`/`cancel()`, so it never blocks recording and is best-effort. Biasing is CTC acoustic rescoring with thresholds — short acronyms are the hard case; tune via `CustomVocabularyTerm` weight/aliases if needed.

### Recording lifecycle (PrototypeViewModel)

`startRecording` → `prepareSelectedEngineIfNeeded` (model download with progress callbacks updating `state.download`) → `transcriber.start(updateHandler:)` → `microphoneCapture.start(...)`. Audio buffers from the mic tap are funneled through `enqueueAudioBuffer` which spawns a per-buffer `Task` so the tap callback never blocks; `drainPendingAudioBuffers` awaits them all on stop. There's an intentional `releaseTailNanoseconds` sleep on stop to let the last audio frames flush before tearing down — don't remove it.

Transcript merging (`mergedConfirmedTranscript`, `partialRemainder`, `longestSuffixPrefixOverlap`) handles streaming overlap between successive partial/confirmed updates from the engine — partial transcripts can re-emit text the confirmed stream has already locked in.

### UI

- `OnboardingWindow` — 5-step wizard (Welcome → Microphone → Accessibility → Mic test → Done). The mic test uses the AppDelegate-owned `onboardingMic` (not the view model's), runs while the test page is on screen, and stops on `onDisappear`. Step indicator dots, auto-advance on permission grant.
- `PrototypeView` — settings window. `NavigationSplitView` + `Form(.grouped)` for the macOS System-Settings look. Sidebar sections: Recording / Voice engine / History / Permissions / About. When the model isn't installed at launch, `autoFocusSetupIfNeeded` jumps the user to the Engine panel; `setupBanner` is rendered at the top of every panel while preparation is in flight.
- `DictationPillWindow` / `PrototypePillView` — floating pill showing audio level + transcription state. `state.hidePillWhenIdle` controls visibility between recordings.
- `DesignTokens.swift` defines `Palette`, `Typography`, and a `card()` modifier. Kept around but the current `PrototypeView` mostly uses native system colors / form styling; new UI should prefer native materials over the custom palette unless there's a specific reason.

### Text injection

`TextInjector` (actor) synthesizes keystrokes via `CGEvent` in 20-UTF16-unit chunks. Requires Accessibility permission; the view model gates injection on `permissionsManager.accessibilityGranted()` and surfaces a "copied to clipboard, enable Accessibility" message on miss rather than failing silently.

### Hotkey

`HotkeyManager` watches `NSEvent.flagsChanged` (both local + global monitors) to detect modifier-key press/release for push-to-talk. Each `HotkeyOption` carries its own `keyCode` and `modifierBit`. Hold-to-talk vs toggle is decided by `state.holdToTalkEnabled` inside the view model's `handleHotkeyPressed/Released`.

## Conventions to keep

- `@MainActor` annotation on classes that touch UI/AppKit; never call them off the main actor.
- `Sendable` on the transcriber protocol — buffer/update closures cross actor boundaries.
- The view model is the ONLY thing that mutates `PrototypeAppState`. Views read; AppDelegate polls; nothing else writes.
- Don't introduce a second status item or second settings window; the AppDelegate's single-instance ownership is load-bearing.
