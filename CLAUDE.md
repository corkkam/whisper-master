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

### Signing & keys (Developer ID + notarization)

- **Code signing:** a **Developer ID Application** cert (Team ID `7MFYAGK3VV`, "subrahmanya s hegde"), created in Xcode → Settings → Accounts → Manage Certificates → + → *Developer ID Application*. `bundle.sh` & `release.sh` default `SIGN_IDENTITY="Developer ID Application"`; pass `SIGN_IDENTITY=-` for an ad-hoc local build. The build enables the **hardened runtime** (`ENABLE_HARDENED_RUNTIME: YES` in `project.yml`) with `Resources/WhisperMaster.entitlements` (only `com.apple.security.device.audio-input` — non-sandboxed; text injection uses Accessibility/TCC, Bonjour needs no entitlement). `bundle.sh` also passes `--timestamp` (secure timestamp, required by notarization) and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` (so the debug-only `get-task-allow` is never injected — the notary service rejects it). The old self-signed **`whisper master`** cert is retired.
- **Notarization:** `Scripts/notarize.sh <path-to-.app-or-.dmg>` submits to Apple's notary service (`xcrun notarytool submit --wait`) and staples the ticket (`xcrun stapler staple`). `release.sh` notarizes+staples the `.app` *before* zipping (the ticket travels in the Sparkle zip); `make-dmg.sh` staples the `.app` then the `.dmg`. **Credentials** (first match wins, read from env / `.env`): `NOTARY_KEY_P8`+`NOTARY_KEY_ID`+`NOTARY_ISSUER` (App Store Connect API key), or `NOTARY_PROFILE` (a name saved once via `xcrun notarytool store-credentials`), or `NOTARY_APPLE_ID`+`NOTARY_PASSWORD`+`NOTARY_TEAM_ID`. If none are set, notarization is **skipped** (build still produced, just not notarized). Notarized + stapled means **no more first-launch `xattr -dr com.apple.quarantine`** — installs and DMG mounts are warning-free.
- **Update signing:** a Sparkle **EdDSA** keypair (Sparkle's `bin/generate_keys`; private key lives in the login keychain, public key is `SUPublicEDKey` in `Info.plist`). Export for CI with `generate_keys -x <file>`. This is independent of the code-signing cert, so the self-signed→Developer ID switch is seamless for already-installed testers (Sparkle validates the unchanged EdDSA key).

### Distribution & auto-update (Sparkle + Cloudflare R2)

- **Hosting:** R2 bucket `whisper-master`, served via the **custom domain `https://model.scoopscore.in`** (Cloudflare CDN — edge-cached, no rate limit). The old `https://pub-033f6365404f4b37ac6c630d4feb0dcd.r2.dev` dev URL is the same bucket and is kept enabled so already-installed apps (with the old `SUFeedURL`) keep polling; new builds use the custom domain. S3 (upload) endpoint `https://db4d52dbca4f08ab7bd161955d66ed6a.r2.cloudflarestorage.com`. Credentials in `.env` (git-ignored; template `.env.example`): `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_BUCKET`, `R2_PUBLIC_BASE_URL`.
- **Layout on R2:** `appcast.xml` + `WhisperMaster-<version>.zip` at the bucket root; model archives under `models/`.
- **`release.sh`** = build+sign (`bundle.sh`) → zip → Sparkle `generate_appcast` (EdDSA-signs, sets the enclosure URL via `--download-url-prefix`) → `rclone` upload of the staged dir. It reads `.env` locally; in CI it reads the same vars from the environment and the EdDSA key from `SPARKLE_ED_PRIVATE_KEY` instead of the keychain.
- **Versioning:** bump **both** `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` before a manual release, or Sparkle won't treat it as newer.
- **⚠️ Never republish a version number.** Each release must use a *new* `CFBundleShortVersionString`, because the archive filename is `WhisperMaster-<version>.zip`. Re-shipping the same version overwrites that file with different bytes while testers/CDN may still hold the old ones — the appcast's `sparkle:edSignature` is computed for the *new* bytes, so Sparkle downloads (possibly Cloudflare-edge-cached) mismatched bytes and fails with **"The update is improperly signed and could not be validated."** This bites silently after a **`git revert`**: the revert changes the code but leaves `CFBundleShortVersionString` unchanged, so the next CI run rebuilds the *same* version with different content. **Fix when it happens:** bump to a fresh version (new filename Cloudflare has never cached) and ship that — do **not** try to re-upload the broken version. The signing certs/EdDSA keys are almost never the actual cause; verify by comparing the served zip's `sign_update` signature against the appcast before blaming signing.

### CI/CD (GitHub Actions)

- Repo is **private** (`HEGADE/whisper-master`); default branch `main`, active work on `dev`.
- **`.github/workflows/release.yml`** has two jobs. A cheap **`gate`** job (Ubuntu, 1× billing) checks whether `CFBundleShortVersionString` changed versus `github.event.before`; only if it did (or on manual `workflow_dispatch`) does the **`release`** job run on `macos-15`: checkout → `brew install xcodegen rclone` → import the **Developer ID** cert from secrets into a temporary keychain → set `CFBundleVersion` to **epoch seconds** (`date +%s`) so it always strictly increases and can't be undercut by an earlier manual build → decode the notary `.p8` → run `release.sh` (which build+sign+**notarize+staple**s). Add **`[skip release]`** to the commit message to skip even a version-bump push.
- **Required repo secrets:** `DEVELOPER_ID_CERT_P12_BASE64` (base64 of the Developer ID `.p12`), `DEVELOPER_ID_CERT_PASSWORD`, `NOTARY_KEY_P8_BASE64` (base64 of the App Store Connect `AuthKey_*.p8`), `NOTARY_KEY_ID`, `NOTARY_ISSUER`, `SPARKLE_ED_PRIVATE_KEY`, plus the five `R2_*` values above. (The CI workflow decodes the `.p8` to `$RUNNER_TEMP` and exports `NOTARY_KEY_P8` for `notarize.sh`.)
- macOS runner minutes bill **~10×** and the Apple notary wait keeps the runner allocated for the whole submission (often 5–30 min today), so each release run is expensive (~hundreds of billed minutes). The **version-bump `gate`** is the primary cost guard — a normal `dev` push that doesn't change `CFBundleShortVersionString` only burns a few Ubuntu seconds; `[skip release]` remains a manual override.

### Release flow, end to end (two ways)

A "release" = put a newer, EdDSA-signed `.zip` + an updated `appcast.xml` on R2; installed apps then self-update via Sparkle. There are two ways to trigger it:

**A. Manual (from your Mac):**
1. Bump **both** `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` (e.g. `PlistBuddy -c "Set :CFBundleShortVersionString 0.1.9" -c "Set :CFBundleVersion 11" Resources/Info.plist`).
2. `bash Scripts/release.sh` → `xcodegen generate` → `xcodebuild -configuration Release` (signed `whisper master`) → `ditto` zip → Sparkle `generate_appcast` (signs the zip with the keychain EdDSA key, writes `appcast.xml` pointing at the R2 public URL) → `rclone` uploads `appcast.xml` + `WhisperMaster-<ver>.zip` to the bucket root.
3. Verify: `curl -s "$R2_PUBLIC_BASE_URL/appcast.xml"` shows the new `sparkle:version`.

**B. CI (push to `dev`):** `git push origin dev` (commit message without `[skip release]`) → the workflow does the same as (A) on a macOS runner, but sets `CFBundleVersion` = **epoch seconds** automatically (always strictly increasing; you still bump `CFBundleShortVersionString` in commits when you want a new human version). Secrets supply the cert + EdDSA key + R2 creds.

**What a tester sees:** their installed app's Sparkle polls `SUFeedURL`, sees a higher `CFBundleVersion`, downloads the signed zip, swaps the app in place, and relaunches — no reinstall. Builds are now **Developer ID-signed and notarized**, so first-ever installs open without any Gatekeeper warning — the `xattr -dr com.apple.quarantine` step is no longer needed.

### Release announcements (Telegram) — the commit message IS the post

After a successful CI release, `Scripts/notify-telegram.py` (final step in `release.yml`) posts to the Telegram group `Corkkam.com` (chat id stored in the `TELEGRAM_CHAT_ID` secret; bot token in `TELEGRAM_BOT_TOKEN`) **and attaches the built app zip** (`build/sparkle/WhisperMaster-<version>.zip` — the Sparkle archive, i.e. the actual `.app`, not a DMG) so people download it straight from the group. **No LLM is involved** — the announcement text is taken verbatim from the release commit message, so write that message as finished, post-ready copy:

- The **body** of the release commit (everything after the subject line) is posted verbatim as the announcement, then reused for X/Twitter. **Write it like a human tweeting, not like release notes.** This is the part to get right — the default tone tends to read AI-generated; actively avoid that:
  - Sound like a person: casual, first-person-ish, contractions, plain words. Lowercase-y is fine. Short punchy lines.
  - Lead with the single thing a user actually cares about. Don't open with a tidy headline like "Fresh X and smoother Y."
  - **Banned AI tells:** the "This release redesigns/introduces/brings…" framing, balanced tricolons (three things joined by em-dashes), "now with X" parentheticals, "seamless/effortless/powerful/robust," marketing CTAs ("Download right here"), and more than one emoji.
  - Keep it short enough to paste into X (a few lines, well under 280 chars). No hashtags, no markdown. Don't claim features that aren't in the release.
  - **Bad (AI slop, don't do this):** "Fresh onboarding and smoother updates. This release redesigns the first-run setup (now with a notifications step), makes update alerts actually show up, and adds a gentle nudge when a Bluetooth mic is hurting audio quality — one tap switches you to the built-in mic. Download the app right here. 🎙️"
  - **Good (human, tweetable):** "new build's up 🎙️ setup's way cleaner, update alerts actually fire now, and if a bluetooth mic is wrecking your audio it'll nudge you to switch to the built-in one (one tap). file's attached, give it a spin."
- If the release commit has **no body**, the script falls back to a `🚀 Whisper Master <version>` heading plus a bullet list of the commit subjects since the last `v*` tag — so even subjects should read as user-facing release-note lines (`Merge`, `release:`, `bump`, and `[skip release]` commits are filtered out).
- The version header and download link are NOT auto-added when a body is present — put whatever headline/version mention you want in the body itself. A `[skip release]` trailer is stripped from the posted text.
- The step is `continue-on-error` and no-ops without the Telegram secrets, so a notification hiccup never fails a release.

**Publishing a model to R2** (separate from app releases): from `~/Library/Application Support/FluidAudio/Models`, `ditto -c -k --keepParent <dir> <dir>.zip`, then `rclone` it to `whisper-master/models/` (creds from `.env`). Done for the engine (`parakeet-tdt-0.6b-v3`) and CTC (`parakeet-ctc-110m-coreml`) models; the app installs them mirror-first via `ModelInstaller`.

## Architecture

### Process / window model

- **Regular Dock app** — `LSUIElement = false` (Info.plist) + `setActivationPolicy(.regular)` (AppMain) → shows a Dock icon and an app menu (`AppDelegate.setupMainMenu`). The menu-bar `NSStatusItem` is still the primary surface, but macOS hides it when the menu bar is crowded (notch), so the Dock icon is the reliable way back in. (Was previously an `.accessory`/`LSUIElement=true` agent with no Dock icon.)
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

**Model install is mirror-first.** `ModelInstaller` (in `ModelInstall/`, with `FileDownloader` + `Archive`) is archive-based — `installIfNeeded(archiveName:destinationRoot:label:maxAttempts:isInstalled:onProgress:)` downloads `<archiveName>.zip` from the public R2 bucket and unpacks it into `destinationRoot`, with an accurate % (R2 returns a real `Content-Length`). It **retries** the download+unpack (`maxAttempts`, default 2) and `FileDownloader` uses **bounded timeouts** (stall + overall, not the 7-day URLSession default) so a stalled transfer fails fast instead of appearing frozen. Only after retries are exhausted does it fall back to FluidAudio's HuggingFace download — and that fallback is **loud, not silent**: logged at `.error` via `Log.modelPrep` (subsystem `app.whispermaster.mac`, persisted to the unified log) and surfaced in the UI (`AppState.usingFallbackModelSource` → "downloading from backup source (slower)"). Note `TranscriberEngine.isInstalled` validates the **actual compiled files** (each required `.mlmodelc`'s `coremldata.bin`), not just that the folder exists — a half-deleted/partial install correctly re-fetches from the mirror instead of masquerading as ready (which used to drop it to the slow HF path). This whole chain was the cause of the intermittent "model loading stuck" bug: a bare-folder `isInstalled` + silent HF fallback + no download timeout. A `TranscriberEngine` convenience overload covers the main engine (`DictationViewModel.installModelsFromMirror`, before `prepareModels`); the CTC vocabulary model uses the generic form. **Both the engine model and the CTC model are hosted on R2.** To publish/refresh an archive: from the models root (`~/Library/Application Support/FluidAudio/Models`), `ditto -c -k --keepParent <dir> <dir>.zip`, then upload to `whisper-master/models/` on R2 (same creds as `release.sh`).

**Custom vocabulary (biasing).** Users maintain a glossary — `PrototypeAppState.customVocabulary` (persisted under `WhisperMaster.customVocabulary.v1`), edited in the Voice-engine **"Words to get right"** field (a raw `@State` draft parsed one-way to `[String]`; don't reintroduce a normalizing two-way binding or Enter/multiline breaks). `FluidAudioStreamingTranscriber.setVocabulary` stores terms (cheap); `loadVocabularyResources` loads FluidAudio's CTC keyword model (R2-first, ~89 MB, guarded against duplicate loads) in the **background** and calls `configureVocabularyBoosting`, biasing decoding toward those terms (e.g. "RAG" not "rack"). It's warmed right after the main engine is ready (`refreshCustomVocabulary`) and re-applied after each session's manager recreation in `stop()`/`cancel()`, so it never blocks recording and is best-effort. Biasing is CTC acoustic rescoring with thresholds — short acronyms are the hard case; tune via `CustomVocabularyTerm` weight/aliases if needed.

### Recording lifecycle (PrototypeViewModel)

`startRecording` → `prepareSelectedEngineIfNeeded` (model download with progress callbacks updating `state.download`) → `transcriber.start(updateHandler:)` → `microphoneCapture.start(...)`. Audio buffers from the mic tap are funneled through `enqueueAudioBuffer` which spawns a per-buffer `Task` so the tap callback never blocks; `drainPendingAudioBuffers` awaits them all on stop. There's an intentional `releaseTailNanoseconds` sleep on stop to let the last audio frames flush before tearing down — don't remove it.

**Microphone capture + the Bluetooth "call mode" issue (`MicrophoneCaptureService`).** A Bluetooth headset can't do hi-fi A2DP playback and mic input at once — the moment any app records from its mic, macOS forces it into the low-quality **HFP "call" profile** (mono, ~8 kHz), degrading both playback *and* the signal we transcribe. This is a **hard Bluetooth limitation, not something an app can tune around.** The reliable fix is for the **user** to set their input to the built-in mic (System Settings → Sound → Input); then the earphones stay in hi-fi and dictation captures a cleaner wideband signal. **⚠️ Do NOT add code that programmatically juggles audio devices to "auto-fix" this — it was tried three times (0.3.5–0.3.6) and every variant broke something:** (1) forcing an input-only device onto `AVAudioEngine` via `kAudioOutputUnitProperty_CurrentDevice` → engine can't start when the output device differs (broke recording); (2) swapping the system default input to built-in for the recording and restoring it on stop → re-routes every recording, races ("works once then stuck"); (3) switching the default input via `kAudioHardwarePropertyDefaultInputDevice` then immediately creating an `AVAudioEngine` and reading `inputNode` HW format → **hung in Core Audio** (`GetHWFormat` blocked on `coreaudiod`, app unresponsive, couldn't even quit). The capture service is intentionally back to the simple known-good form: reuse one `AVAudioEngine`, capture from the system default input, **no device manipulation in the recording path** — leave it that way. The **safe** way to help (shipped): `BluetoothInputMonitor` (read-only poll, off-main) detects a Bluetooth default input and sets `AppState.bluetoothInputActive`; the notch then shows `NotchBluetoothBanner` ("Bluetooth mic lowers quality → Use built-in") and, only when the *user taps it*, `AudioInputDevices.switchToBuiltInMic()` does **one** `kAudioHardwarePropertyDefaultInputDevice` set off the main thread (the same op as Sound settings), while idle and nowhere near the engine. That decoupling — user-initiated, off-main, not in the capture flow — is what makes it safe vs. the auto-switch that hung. The pill panel is click-through except while the banner is up (`DictationPillWindow.setInteractive`, driven by `AppState.shouldShowBluetoothBanner` from the refresh loop).

Transcript merging (`mergedConfirmedTranscript`, `partialRemainder`, `longestSuffixPrefixOverlap`) handles streaming overlap between successive partial/confirmed updates from the engine — partial transcripts can re-emit text the confirmed stream has already locked in.

### Gentle reminders (`Reminders/`)

Because the app lives in the notch with no window to return to, a user can forget it exists. The fix is a **gentle nudge reused through the existing notch surface** — not a native `UNUserNotification`: when the app has been idle a while, the black notch band drops down with a short friendly line (`NotchReminderBanner`) for ~5s, silent and click-through, then retracts. Four small pieces: `ReminderPolicy` (pure, deterministic — takes `now`, holds all tunable timing: 3h baseline → 6h → 12h backoff, daily cap, display duration), `ReminderBookkeeping` (Codable cadence state persisted under `WhisperMaster.reminders.v1`), `ReminderCopy` (the rotating lines), and `ReminderScheduler` (`@MainActor` driver, owned by `DictationViewModel` — the sole `AppState` writer — that consults the policy and sets `AppState.activeReminder`). The **AppDelegate 0.5s refresh loop** calls `viewModel.evaluateReminders()` each tick (idle-gated, cheap). A completed dictation calls `reminderScheduler.noteUsed()`, resetting backoff to the friendly baseline; `startRecording` calls `clear()` so the live indicator never collides with a reminder. Safety rests on three independent layers, not on context detection (which was deliberately dropped — no DND/Focus, meeting, or screen-share detection): the artifact is intrinsically gentle, a Settings **"Gentle reminders"** toggle (`AppState.remindersEnabled`, **off by default — opt-in**; while off the scheduler is dormant and resets its cadence so a later opt-in starts a fresh idle gap) is a hard off-switch, and the conservative cadence means few firings. Spec: `docs/superpowers/specs/2026-06-30-gentle-notch-reminders-design.md`.

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
