# Gentle Notch Reminders — Design

**Date:** 2026-06-30
**Branch:** `feat/reminder-for-user`
**Status:** Approved for planning

## Problem

The app lives in the menu bar / notch and is invoked by a push-to-talk hotkey.
Because there's no window to return to, a user who hasn't dictated in a while can
simply *forget the app exists*. We want a gentle nudge that reminds them the app
is there — conveying only "it's been a while since you used me," nothing more.

## Decision: reuse the existing notch surface, not native notifications

The reminder is shown by **dropping the existing notch surface down with a short
friendly line**, then retracting it — the same black `NotchShape` already used
for recording / download / error states. We do **not** post a macOS
(`UNUserNotification`) banner for this. The notch drop-down is silent, small,
non-interactive, and auto-dismisses, which is exactly the "gentle" feel we want.

## Safety philosophy

The feature must never make a user feel interrupted or embarrassed (e.g. a nudge
slipping out while they present). Rather than rest safety on fragile detection,
safety comes from **three independent layers**, none of which depend on detecting
the user's context:

1. **The artifact is intrinsically gentle.** A small, *silent* black tab slides
   out of the notch for ~5 seconds and retracts on its own. No sound, no banner,
   no stolen focus, nothing to click. Worst case — it appears at an unwanted
   moment — it is a brief, ambient non-event, not a dinging banner.
2. **A guaranteed off-switch.** A "Gentle reminders" toggle in Settings (on by
   default). One flip disables them permanently, with no dependency on any
   detection logic. This is the user's hard guarantee.
3. **Conservative cadence.** Backoff plus a daily cap means few firings, so few
   chances to ever appear at a bad moment.

**Explicitly out of scope** (decided during brainstorming): DND/Focus detection,
meeting detection, screen-share/screen-capture detection, and quiet hours. The
three layers above make these unnecessary, and DND/Focus has no stable public
API anyway.

## Components

Three small pieces, each with one responsibility:

### 1. `ReminderPolicy` (new — pure logic, no UI/AppKit)

The brain. A pure, independently testable type that decides *whether* to nudge
now and *which* line to show. It takes `now` as an input (never reads the clock
itself), so it is fully deterministic and testable.

```
struct ReminderPolicy {
    // All tunable timing lives here as named constants.
    static let baselineIdleGap: TimeInterval   = 3 * 3600      // 3h since last use
    static let backoffGaps: [TimeInterval]     = [3, 6, 12].map { $0 * 3600 }
    static let maxNudgesPerDay: Int            = 3
    static let minSpacingBetweenNudges: TimeInterval = 3 * 3600

    /// Decide whether a nudge should fire right now.
    func shouldNudge(now: Date, input: ReminderState) -> Bool

    /// Pick the next friendly line (rotating, avoids immediate repeat).
    func nextLine(now: Date, lastIndex: Int?) -> (line: String, index: Int)
}
```

`ReminderState` is a small value carrying `lastUsedAt`, `lastNudgeAt`,
`nudgesSinceLastUse`, `nudgesToday` (+ the day they were counted), and
`lastLineIndex`. The policy reads these; it does not mutate global state.

The **cadence rule**: first nudge fires once the idle gap since `lastUsedAt`
exceeds `baselineIdleGap` (3h). After a nudge fires with no intervening use, the
required gap grows along `backoffGaps` (3h → 6h → 12h, then holds at the last
value). Firing is additionally rate-limited by `minSpacingBetweenNudges` and
capped at `maxNudgesPerDay`. **Any completed dictation resets** the backoff and
counters to baseline.

### 2. `AppState` additions

`AppState` (the single `@Observable`, `@MainActor` source of truth — view model
is the only writer) gains:

- `lastUsedAt: Date?` — **persisted** (UserDefaults, iso8601, same pattern as
  history). Stamped on every completed dictation.
- Reminder bookkeeping — **persisted** so backoff survives relaunch:
  `lastNudgeAt: Date?`, `nudgesSinceLastUse: Int`, `nudgesToday: Int` (+ its
  day), `lastLineIndex: Int?`.
- `remindersEnabled: Bool` — **persisted**, default `true`. Bound to the
  Settings toggle.
- `activeReminder: String?` — **transient** (not persisted). The line currently
  being shown in the notch; `nil` when nothing is showing.

New UserDefaults keys follow the existing `WhisperMaster.<thing>.vN` convention.

### 3. Notch UI (extends existing views)

- `DictationPillContent` — `hasContent` / `isExpanded` extended so that a
  non-nil `state.activeReminder` also drops the surface down (alongside the
  existing recording/download/error cases). The existing spring animation is
  reused.
- `DictationStatusView` — a new branch renders the reminder line (white text,
  short) when `state.activeReminder != nil` and no higher-priority state
  (recording/download/error) is active. Working states take precedence over a
  reminder — we never replace a live indicator with a nudge.

**Implementation note / open detail for the plan:** the notch bottom band is
currently sized for a small glyph, not a text line. The plan must address fitting
a short line — most likely by keeping copy very short and/or letting the surface
width accommodate the text via `NotchSurfaceLayout`. Copy is kept short
specifically to make this easy.

## Data flow & lifecycle

1. **On completed dictation**, the view model stamps `state.lastUsedAt = now`
   (persisted) and resets reminder bookkeeping (`nudgesSinceLastUse = 0`,
   backoff back to baseline). Natural hook: alongside `appendHistory`.
2. **The AppDelegate 0.5s refresh timer** (already the AppKit↔state bridge) is
   the only thing that drives reminders. Each tick, *only when the app is idle*
   (phase `.idle`, no active reminder already showing) and `remindersEnabled`,
   it asks `ReminderPolicy.shouldNudge(now:input:)`.
3. **When the policy says yes:** pick a line via `nextLine`, set
   `state.activeReminder = line`, stamp `lastNudgeAt = now`, bump
   `nudgesSinceLastUse` / `nudgesToday`, store `lastLineIndex` (all persisted).
   The notch drops down on the next render.
4. **A short dismissal timer (~5s)** clears `state.activeReminder` → notch
   retracts. Silent throughout. Click-through behavior is unchanged (nothing to
   click; it just disappears).
5. **Starting a recording** while a reminder is showing immediately clears
   `activeReminder` so the live indicator takes over cleanly.

The policy never reads the clock; the timer passes `now`. This keeps all timing
logic in one testable unit.

## Copy

A small rotating set, minimal and friendly, lowercase-casual, **no emoji**
(ages better, less gimmicky). Kept short to fit the notch. Initial set:

- still here when you need me
- got something to say? i'm listening
- psst — i can type that for you
- ready whenever you are
- miss me? i'm one shortcut away

`nextLine` rotates and avoids repeating the immediately previous line. The list
lives next to `ReminderPolicy` so copy is easy to edit.

## Settings

A "Gentle reminders" toggle (on by default) added to the Recording settings
section, bound to `state.remindersEnabled`. Off = no reminders, ever.

## Testing

`ReminderPolicy` is pure and gets unit-style coverage by feeding synthetic
`now` / `ReminderState` values:

- No nudge before the baseline gap; nudge once it's exceeded.
- Backoff grows the required gap after each ignored nudge (3h → 6h → 12h).
- `minSpacingBetweenNudges` and `maxNudgesPerDay` both enforced.
- A completed dictation (`lastUsedAt` advanced) resets backoff/counters.
- `nextLine` never repeats the immediately previous index.

(There is no test suite harness in this repo today; tests are written against
`ReminderPolicy` as plain logic and can be run via `swift build`/a lightweight
check. The plan will specify the exact mechanism.)

## Out of scope

- DND/Focus, meeting, screen-share/capture detection; quiet hours.
- Native `UNUserNotification` banners for reminders.
- Brand/wordmark/logo in the reminder (decided: minimal line only).
- Any change to the recording/download/error notch behavior.
