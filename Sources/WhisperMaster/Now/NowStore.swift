import Foundation
import Observation

#if canImport(EventKit)
import EventKit
#endif

/// What is relevant right now, kept fresh enough for the bezel and no fresher.
///
/// It owns two things: today's events (read through the same `DaySummaryService`
/// fan-out the spoken "what's my day" answer uses, so the notch and the assistant
/// can never disagree about the day) and the single `NowItem` the ambient row
/// carries.
///
/// **It starts dormant.** `swift test` and the headless snapshot renderer must
/// never open an `EKEventStore` or arm a timer, so nothing happens until `start()`
/// is called from the post-auth bring-up — the same posture as
/// `AgentSurfaceController` and `UsageStore(load: false)`.
///
/// **Two cadences, deliberately different.** The *item* is recomputed once a
/// minute, because `NowPhrase` has no unit smaller than a minute and a surface
/// that repainted faster would be spending battery to show the same string. The
/// *events* are re-read only when EventKit says they changed, plus a slow backstop
/// — reading the store is far more expensive than re-ranking a handful of values
/// already in memory, and a calendar does not change on a one-minute cadence.
@MainActor
@Observable
final class NowStore {
    /// Today's events, newest read. Empty until the first refresh, and empty
    /// forever if calendar access was never granted.
    private(set) var events: [DayEvent] = []

    /// The one thing worth the bezel, or `nil` for a dark notch.
    ///
    /// **Assigned only when it actually changes.** `@Observable` notifies on every
    /// write, equal or not, and this is written on a repeating timer — an
    /// unguarded assignment here would invalidate the notch surface once a minute
    /// for the life of the process, which is exactly the cost the tray refresher's
    /// change guards exist to avoid.
    private(set) var item: NowItem?

    /// When the events were last read, for the Settings diagnostics line.
    private(set) var lastEventRead: Date?

    private let connectors: ConnectorInstanceStore
    private let notes: NotesStore

    private var tick: Timer?
    private var eventChangeObserver: NSObjectProtocol?
    /// Ticks since the last event read, so the backstop is counted rather than
    /// timed by a second timer.
    private var ticksSinceRead = 0

    /// How many one-minute ticks pass before the events are re-read even though
    /// EventKit reported nothing. A backstop for the change notification not
    /// arriving (a subscribed `.ics` refreshing in the background does not always
    /// post one), not the primary path.
    static let readBackstopTicks = 10

    init(connectors: ConnectorInstanceStore, notes: NotesStore) {
        self.connectors = connectors
        self.notes = notes
    }

    // No `deinit` teardown: the observer and the timer are both main-actor state
    // and `deinit` is nonisolated, so it cannot touch them. `stop()` is the
    // teardown, called on sign-out — and the observer block holds `self` weakly, so
    // a store that is released without it is inert rather than leaked.

    var isRunning: Bool { tick != nil }

    // MARK: - Lifecycle

    /// Begin reading the calendar and ranking the day. Idempotent.
    func start(now: Date = Date()) {
        guard tick == nil else { return }

        #if canImport(EventKit)
        eventChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.readEvents()
                self?.recompute()
            }
        }
        #endif

        // Aligned to the minute boundary rather than to launch, so the countdown
        // turns over when the clock does. A row reading "in 6m" while the menu bar
        // clock has already moved on is the kind of small wrongness that makes a
        // surface feel untrustworthy.
        let timer = Timer(fire: Self.nextMinute(after: now), interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer

        readEvents(now: now)
        recompute(now: now)
    }

    /// Stop everything and forget the day. Called on sign-out — the events belong
    /// to the account that was signed in.
    func stop() {
        tick?.invalidate()
        tick = nil
        if let eventChangeObserver {
            NotificationCenter.default.removeObserver(eventChangeObserver)
            self.eventChangeObserver = nil
        }
        events = []
        lastEventRead = nil
        if item != nil { item = nil }
    }

    private func onTick() {
        ticksSinceRead += 1
        if ticksSinceRead >= Self.readBackstopTicks { readEvents() }
        recompute()
    }

    /// The next whole minute after `now`, so the tick lands on the clock's own
    /// boundary instead of wherever the app happened to launch.
    static func nextMinute(after now: Date) -> Date {
        let seconds = now.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.down) * 60 + 60)
    }

    // MARK: - Reads

    /// Re-read today's events. Cheap enough to call on a notification, too
    /// expensive to call on every tick.
    func readEvents(now: Date = Date()) {
        ticksSinceRead = 0
        let read = DaySummaryService.build(store: connectors, now: now).events
        guard read != events else { return }
        events = read
        lastEventRead = now
    }

    /// Re-rank what is already in memory. Pure apart from the two reads.
    func recompute(now: Date = Date()) {
        let picked = NowRelevance.pick(
            events: events, reminders: notes.visibleReminders, now: now)
        guard picked != item else { return }
        item = picked
    }

    /// Force both halves — used by the Settings toggle and after a reminder is
    /// ticked from the bezel, where waiting up to a minute for the row to catch up
    /// would read as the tap having done nothing.
    func refreshNow(now: Date = Date()) {
        readEvents(now: now)
        recompute(now: now)
    }

    // MARK: - The day

    /// Inject a day directly, bypassing EventKit.
    ///
    /// For the headless snapshot renderer and unit tests only — `readEvents` is the
    /// one path the app itself ever takes. It exists because the alternative is a
    /// protocol seam over `DaySummaryService` for the sake of two callers that both
    /// want a fixed answer, and because a renderer that opened an `EKEventStore`
    /// would prompt for calendar access on a machine building screenshots.
    func seed(events: [DayEvent], now: Date = Date()) {
        self.events = events
        recompute(now: now)
    }

    /// Today in one ordered list, for the hover panel.
    ///
    /// `keeping` is the set of reminders ticked off during the current glance,
    /// which stay on screen struck through so the tick can be undone on the bezel.
    func timeline(now: Date = Date(), keeping: Set<UUID> = []) -> [NowTimelineRow] {
        NowTimeline.rows(
            events: events, reminders: notes.visibleReminders, now: now, keeping: keeping)
    }
}
