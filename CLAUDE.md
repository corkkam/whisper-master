# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A standalone macOS menu-bar app prototype for local-first streaming dictation, built on `FluidAudio` + NVIDIA Parakeet. **Intentionally separate** from the sibling project `/Users/ninja/coding/lyzr-exprmt/lyzr-whisper` — do not cross-modify; this is the sandbox for evaluating on-device streaming ASR on Apple Silicon.

## Commands

```bash
# Dev build (debug)
swift build
.build/debug/WhisperMasterPrototype     # runs from CLI; uses LSUIElement so no Dock icon

# Release .app (build → codesign with keychain identity "whisper master")
bash Scripts/bundle.sh                  # produces build/Whisper Master.app
CONFIG=debug bash Scripts/bundle.sh     # debug-config variant

# DMG (chains through bundle.sh)
bash Scripts/make-dmg.sh                # full rebuild + DMG
REBUILD=0 bash Scripts/make-dmg.sh      # repackage existing .app only

# One-shot install: build → quit running instance → replace /Applications/Whisper Master.app → relaunch
bash Scripts/install.sh
REBUILD=0 bash Scripts/install.sh       # skip rebuild
RELAUNCH=0 bash Scripts/install.sh      # install without launching
```

Codesigning identity is hardcoded to `whisper master` (override with `SIGN_IDENTITY=…`). Build is arm64-only, macOS 14+.

There is no test suite.

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

### Transcription engines

`TranscriberEngine` enum has two cases (`eouStreaming`, `slidingWindow`) implemented by `FluidAudioEouStreamingTranscriber` and `FluidAudioStreamingTranscriber` respectively. Both conform to `LocalStreamingTranscriber` (Sendable). `PrototypeViewModel.transcriber` dispatches to the right one based on `state.selectedEngine`. Models are downloaded on demand into `~/Library/Application Support/FluidAudio/Models/<cacheDirectoryName>` — `TranscriberEngine.isInstalled` is a filesystem check, so callers must not cache it.

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
