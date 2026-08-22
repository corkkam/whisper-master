# Now (`Sources/WhisperMaster/Now/`)

What is relevant *right now*, ranked down to the one thing the notch carries.

The app has read the calendar since the spoken day summary shipped
(`CalendarConnector` → `DaySummaryService`), but no notch surface read it: the
bezel spoke only when the app itself was doing something. This directory is the
answer to "show me my day without me asking", and the whole of it is pure and
clock-injected apart from `NowStore`.

### The relevance ladder is a total order, not a filter

`NowRelevance.pick` returns **at most one** `NowItem`. The notch is a
single-occupancy surface, so a list is not an answer — two equally plausible
candidates would make the row flicker between them as the clock moves. The rungs,
highest first:

1. a meeting in progress (the most recently *started* one, so a stand-up inside a
   long focus block is what gets named)
2. a meeting inside `meetingHorizon` (10 min)
3. a reminder that is overdue and unanswered (the **oldest**, because that is the
   one being ignored)
4. a reminder inside `reminderHorizon` (15 min)
5. the next event inside `lookahead` (60 min) — orientation, not news, so it is
   the one rung drawn colourless
6. nothing. **The notch stays dark**, which is the common case and the point: an
   ambient surface that is never empty is a dashboard, and this app is not one.

**All-day events never produce an item.** They have no moment to count down to, so
"Company offsite in 6m" would be a lie about something true for sixteen hours.
They still appear in `NowTimeline`, where the day has room to say "All day".

**Coding agents are deliberately not a rung.** A blocked or finished agent already
has `NotchAgentAskBanner`, `AgentAttention` and the tray submenu, all of which
outrank anything ambient. A sixth rung here would be two systems racing to
describe the same session.

### Nothing counts in seconds

`NowPhrase`'s smallest unit is the minute, rounded **up** (a meeting 30 seconds out
reads "in 1m", never "in 0m"), and it switches to hours past 90 minutes because
nobody converts "in 118m". This is the band's no-pulse rule reached by another
route: a countdown redrawing every second is perpetual motion on the bezel, and the
record dot's breathe is the system's only one. `NowStore`'s tick is aligned to the
**minute boundary** rather than to launch, so the row turns over when the menu-bar
clock does.

### `NowStore` has two cadences and starts dormant

Ranking what is already in memory is cheap; reading EventKit is not. So the *item*
is recomputed once a minute and the *events* are re-read only on
`EKEventStoreChanged`, plus a slow counted backstop (`readBackstopTicks`) for the
subscribed-`.ics` refreshes that do not post one.

It **starts dormant** — `start()` runs from `proceedAfterAuthIfNeeded` with the rest
of the post-gate bring-up — so `swift test` and the headless snapshot renderer never
open an `EKEventStore` or arm a timer. Same posture as `AgentSurfaceController` and
`UsageStore(load: false)`. `seed(events:)` is the test/renderer seam; the app never
calls it.

**⚠️ `item` is assigned only when it changes.** `@Observable` notifies on every
write, equal or not, and this one is written on a repeating timer — an unguarded
assignment would invalidate the notch surface once a minute for the life of the
process. Same class of permanent background cost as the tray refresher's change
guards.

`stop()` runs on sign-out and clears everything: the day belongs to the account
that was signed in.

### `ConferenceLink` is an allowlist, and that is the design

A meeting countdown you cannot join is a nag, so `DayEvent.joinURL` carries the
call. It is resolved **once at read time**, not each time a surface draws the
event — the notch row repaints every minute and re-scanning a wall of invitation
notes on each of those is work nobody asked for.

**⚠️ Never relax it to first-URL-wins.** An invitation body routinely carries an
unsubscribe link, a room-booking link and a wiki page, and the first URL in a
Google invitation is often the calendar entry itself. Opening one of those when
someone asked to join a call is worse than showing no button, so an unrecognised
host yields `nil` and no Join affordance is drawn at all. A bare host with no path
is rejected too (that is a marketing page). The allowlist is applied **again** in
`AppDelegate.openConferenceLink`, because the URL travels through a value type and
a SwiftUI closure to get there and `NSWorkspace.open` will happily launch a
`file://`.

### `NowTimeline` is the hover panel's day

One ordered column, events and reminders **interleaved by time**. "What is on my
plate" is one question, and answering it in two lists makes the reader merge them
by eye — which is what the old reminders-beside-notes panel asked for, while
leaving the calendar out entirely.

- Reminders are narrowed to **today, plus anything overdue and unanswered**. The
  store holds every reminder ever set, so passing it straight through would put
  next month's dentist appointment under a heading that says Today.
- What has gone is **dimmed, not dropped** — a day with its morning deleted reads
  as an empty day.
- `window` gives the room to what is **ahead**, and lets the most recent past fill
  whatever is left, so a finished day still shows its tail. It re-reads the kept
  rows out of the original array rather than concatenating two buckets, because an
  all-day row sorts first but is never `isPast` and concatenation dropped it below
  the morning.
- Nothing is silently truncated: past `displayLimit` the column says how many rows
  it left out.

Surfaces: `UI/NotchNowRow.swift` (the ambient row) and
`UI/QuickActions/NotchDayTimelineColumn.swift` (the day). Both are covered by
`NowRelevanceTests`, `NowTimelineTests` and `ConferenceLinkTests`.
