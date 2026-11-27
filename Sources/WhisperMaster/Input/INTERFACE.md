---
component: Input
owner: c-input
interface_version: 1
last_verified: 2026-11-27
verified_by: cd whisper-master && swift test --filter HotkeyGestureTests --filter SelectionContextTests --filter RefinementDiffTests --filter CorrectionDetectorTests --filter TerminalAppsTests
---
# Input interface

Bare file names are inside `whisper-master/Sources/WhisperMaster/Input/`.

## Purpose

Turns key presses into recording events. Puts finished text into the front app. Reads the front app's selection, edits pasted text in place, and learns word fixes. It uses AppKit and Accessibility (AX) only.

## Entry points

- `HotkeyManager` (`@MainActor`) watches `.flagsChanged` and emits `Event` (`start`, `stop`, `handsFree`, `toggle`). `HotkeyOption` lists the keys: `fn`, `rightOption`, `leftOption`, `rightCommand`. Methods: `init(hotkey:latchesOnDoubleTap:holdToTalk:onEvent:)`, `setHotkey(_:)`, `resetGesture()`.
- `HotkeyGesture` is the pure recogniser: `press(now:)`, `release(now:)`, `flush(now:)`, `reset()`.
- `ModifierChord.command` is the fn + control chord. `ModifierChordMonitor` emits `.engaged` and `.released`.
- `FnKeyBehavior` reads and writes the system `AppleFnUsageType`: `current`, `claimFnKeyForPushToTalk()`, `restoreSystemFnBehavior()`, `conflictsWithPushToTalk`.
- `TextInjector` (actor): `inject`, `pressCommandV`, `deleteBackward`, `moveLeft`.
- `FocusedElementInspector`: `editableTarget()`, `focusHasNoTextTarget()`, `focusedElement()`, `selectedRange(of:)`, `stringValue(of:)`.
- `InPlaceRefiner.apply(pasted:refined:element:injector:)` and `RefinementDiff.plan` and `caretEdit`.
- `TerminalApps`: `bundleIDs`, `isTerminal(bundleID:)`, `frontmostIsTerminal()`, `secureKeyboardEntryEnabled()`.
- `SelectionReader` (`state(_:)`, `read(_:)`, `.live`), `SelectionContext`, and `SelectionCapture` (`begin`, `take`, `state(in:)`, `settle`).
- `CorrectionDetector.detectSingleWordReplacement(injected:current:)` and `CorrectionLearner.watch(injected:onLearn:)`.

## Inputs and outputs

- In: modifier-key events, the front app's AX tree, the pasteboard, the finished transcript.
- Out: recording events, synthesized key events, text in the front app, `SelectionContext`, learned word fixes.
- The model sees at most 8,000 selection characters. A run of 40 or more repeated characters becomes a placeholder.
- The system key setting `AppleFnUsageType` is the one system value this folder writes. It goes through `CFPreferences`.

## Errors and invariants

- `.start` fires on the key press, never after a delay.
- `stopRecording` must reset the gesture. Toggle mode skips the recogniser.
- Start the recording first, then begin the selection read.
- Set the AX timeout per element, never on the system-wide element.
- Re-read `AppleFnUsageType` after a write. Never report unverified success.
- Claim the Globe key once, only when the user chose fn, and record the old value. The claim runs after sign-in.
- Terminals always take the clipboard plus Command-V path.
- `InPlaceRefiner` edits only when the same element has focus, the caret is collapsed, and the text before the caret equals the pasted text. Tail rewrites stop at 80 characters.
- Auto-learn stays conservative: similarity at least 0.3 and at least 3 words.
- Secure Keyboard Entry blocks synthesized keys. Code cannot bypass it.

## Architecture

- `HotkeyManager` feeds raw flag changes into `HotkeyGesture`, which decides the event.
- One `HotkeyManager` serves push-to-talk. A second one serves the optional coding-agent key.
- The chord monitor is separate. `AppDelegate.setupHotkey()` installs it with no dependence on the agent key.
- After dictation, `TextInjector` pastes the text. `InPlaceRefiner` may then rewrite it through AX.
- `CorrectionLearner` polls the field after a paste and reports one fixed word.
- Chrome and Electron hide the AX tree, so selection reads there return unknown.
- No test covers `FnKeyBehavior`, `TextInjector`, `InPlaceRefiner`, `ModifierChordMonitor` or `CorrectionLearner`. Check them by hand.

## Do not

- Do not infer intent from the words. Holding the push-to-talk key dictates and nothing else.
- Do not call `DayQueryDetector.matches` outside `routeCommandCapture`.
- Do not read a selection in a private app or under secure input. Never persist selection text.
- Do not reuse the defaults key `WhisperMaster.dayQueryHotkey.v1`.
- Do not rename a `HotkeyOption` case. The raw value is stored, and a rename resets users to `.fn`.
- Do not run blanket `swiftformat`. Use `@MainActor` for AppKit code.

## Used by

- `whisper-master/Sources/WhisperMaster/App/`: `AppDelegate` builds the managers and the chord monitor. `AppState` stores `HotkeyOption`. `DictationViewModel` pastes, refines and learns.
- `whisper-master/Sources/WhisperMaster/UI/Settings/` and `whisper-master/Sources/WhisperMaster/UI/Onboarding/` use `FnKeyBehavior`, `ModifierChord` and `HotkeyOption`.
- `whisper-master/Sources/WhisperMaster/Connectors/` uses `TerminalApps`, the selection types and `privateApps`.
