---
component: UI
owner: c-ui
interface_version: 1
last_verified: 2026-11-27
verified_by: cd whisper-master && swift test --filter NotchSurfaceLayoutTests --filter NotchQuickActions --filter NotchHoverGestureTests --filter ApprovalCopyTests --filter NotchAgentPanelTests --filter OnboardingCopyTests --filter ReleaseChannelTests
---
# UI interface

Bare file names are inside `whisper-master/Sources/WhisperMaster/UI/`. Subfolders: `Agents/`, `AgentFaces/`, `Components/`, `Meetings/`, `Motion/`, `Onboarding/`, `QuickActions/`, `Settings/`, `WhatsNew/`.

## Purpose

All SwiftUI and AppKit views. It holds the design tokens, the main window, and the notch surfaces: the dictation band, the hover band, onboarding, the agent panels and the Crew rail. Views read `AppState` and call closures. They do not own app state.

## Entry points

- Tokens: `Theme` (colors, `Space`, `Shadow`, `Motion`, `Notch`, `Sticky`), `Typography`, `BrandFont.registerAll()`, `BrandAsset`, `BrandLogo`. Surface modifiers: `.glassCard()`, `.glassTile()`, `.glassPanel()`, `.card()`.
- Dictation notch: `DictationPillWindow` (`show()`, `hide()`, `setInteractive(_:)`), `DictationPillContent`, `DictationStatusView`, `NotchActivity.resolve(from:)`, `NotchGeometry`, `NotchSurfaceWidth`, `NotchSurfaceLayout`, `NotchBannerRow`, `NotchApprovalBanner.thickness(for:banner:)`, `PointerScreen.current()`.
- `Components/`: the button ladder `.primaryButton()` to `.destructiveButton()`, `.iconButton()`, `.onDarkSurface()`. Cursor bridges `.pointerCursor()`, `.iBeamCursor()`, `.nativeTooltip()`. Also `SecretField`.
- `Settings/`: `SettingsView` and `SettingsSection` host each `*SettingsView` page. Shared pieces: `SettingsCard`, `SettingsRow`, `StatTile`, `Chip`, `RowTag`, `ThemeToggle`.
- `QuickActions/`: `NotchQuickActionsWindow` (`start()`, `stop()`, `suspend()`, `resume()`, `dismiss()`), `NotchQuickActionsModel`, `NotchConnectorLinks.isOpenable(_:)`.
- `Onboarding/`: `NotchOnboardingWindow` (`show()`, `handOff()`, `close()`), `OnboardingFinishPlan`, `OnboardingStagePanel`.
- `Agents/`: `NotchAgentPanel`, `NotchAgentGlance`, `NotchAgentReplyExpanded`, `AgentModeControl`.
- `AgentFaces/`: `AgentRailPanel(onSelect:)` with `update(items:)`. It opens itself for a non-empty list and closes itself for an empty one.
- Other windows: `MeetingLiveWindow`, `WhatsNewWindow`. `SettingsView` hosts `ShedCodingView` (in `Agents/ShedPage.swift`).

## Inputs and outputs

- In: `AppState` and its stores (notes, connectors, usage, agents), plus injected closures.
- Out: window and panel state, user actions through closures, and PNG renders in snapshot mode.
- Snapshot mode (`WM_SNAPSHOT=<dir>`, Debug only) renders every surface with no live service.

## Errors and invariants

- `NotchActivity.resolve` keeps the branch order of `DictationStatusView`.
- The panel is sized once. A new banner height feeds `maxBandThickness`.
- An interactive banner must join `allowsHitTesting` and `setInteractive`. Passive parts stay click-through.
- `extraWing` must not read `ambientSlot`. It overflows the stack.
- The hover band shows only while open. Hover is polled at 0.06 s. Tabs switch on click only.
- Pinned-tab links need `isOpenable` and a re-check before `NSWorkspace.open`.
- Onboarding strings live in `OnboardingCopy`.
- `Theme.Sticky` order is append-only, because `Note.colorIndex` is stored.
- Every `NSViewRepresentable` overlay needs the `\.isSnapshot` gate, because `ImageRenderer` cannot draw it.
- A tick that writes a frame every time is a permanent cost. Guard each AppKit write by change.

## Architecture

- `Theme` tokens feed the `Components/` ladder. Views use both and no raw values.
- The app is light-only. `.onDarkSurface()` marks an always-ink subtree, such as a notch band.
- Ember is the user. Signal is the machine. Never swap them.
- `DictationPillContent` resolves one `NotchActivity` and one transcript wrap, and hands them down.
- A wider banner than `panelSize` clips inside its own window.
- The Crew rail is `AgentRailPanel`. `AppDelegate.reconcileCrewRail()` feeds it from `CrewAgents`, in dev builds only.

## Do not

- Do not use raw hex or a bare `.buttonStyle(.plain)`. Use `Theme` tokens and the button ladder.
- Do not put two `.primaryButton()` in one view. Add a `ButtonRung`, not a new `ButtonStyle`.
- Do not add a mode-aware color token. Do not add a dark mode.
- Do not show the live transcript in the dictation band.
- Do not cut or refuse approval text for length.
- Do not add or remove the onboarding band `TimelineView`.
- Do not run blanket `swiftformat`.

## Used by

- `whisper-master/Sources/WhisperMaster/App/AppDelegate.swift` creates the main, pill, hover-band and onboarding windows and handles pill clicks.
- `whisper-master/Sources/WhisperMaster/App/SnapshotMode.swift` renders every PNG.
- `whisper-master/Sources/WhisperMaster/Auth/` uses `Theme`. `whisper-master/Sources/WhisperMaster/Notes/AlarmWindow.swift` uses `WarmBackground`.
- `whisper-master/Sources/WhisperMaster/Meetings/` and `whisper-master/Sources/WhisperMaster/WhatsNew/` create windows.
