import Foundation
import Observation

/// Drives the hover quick-actions panel: whether it's open, and what the two
/// columns are holding.
///
/// **The left column is the day, not a list of reminders.** It used to be a
/// reminders column beside a notes column, which answered two thirds of "what is
/// on my plate" and left the calendar — which the app has read all along for the
/// spoken day summary — out of the one surface built for exactly that question.
/// Events and reminders are now interleaved by time in a single ordered column
/// (`NowTimeline`), because they are one question and two lists make the reader
/// merge them by eye.
///
/// **The open/close decision lives in `NotchHoverGesture`** — a pure dwell/grace
/// machine (crossing the notch on the way to the menu bar must not open anything),
/// unit-tested on its own. This type is the wiring around it: what the two columns
/// hold, and whether the panel is allowed up at all.
///
/// It never writes to `AppState` beyond the one-shot navigation requests the window
/// hands to the App layer — the dictation view model stays that state's only writer.
@MainActor
@Observable
final class NotchQuickActionsModel {
    /// Most rows the **notes** column shows. Past this it stops being a glance.
    /// The day column has its own, wider limit (`NowTimeline.displayLimit`) — it is
    /// the reason to open the panel, so it gets the room.
    static let columnLimit = 3
    /// Most rows the **Notes tab** shows — the tab is the whole band, so it holds
    /// more than the column on Today does.
    static let notesTabLimit = 5

    var isOpen: Bool { gesture.isOpen }

    /// Read by the Settings tab's switches, which bind to the same preferences the
    /// Settings window does.
    let state: AppState
    /// What the pinned connections hold. Owned here so it lives as long as the band.
    let feed: NotchConnectorFeed
    /// The tab the user last chose. Read through `currentTab`, which drops a
    /// connector tab whose pin has since been removed.
    private var chosenTab: NotchQuickActionsTab
    /// False for the snapshot renderer, so rendering a tab never moves a real user's
    /// band onto it.
    private let persistsTab: Bool
    private var gesture = NotchHoverGesture()
    /// Reminders ticked off during this glance, keyed by id and holding the copy
    /// they were in **before** the tick.
    ///
    /// Two jobs. It keeps a just-ticked row on screen (a row that vanished the
    /// instant you clicked it left nowhere to click again, so the tick was
    /// one-way), and it holds the snapshot `NotesStore.restoreReminder` needs to
    /// put a repeating reminder back on the occurrence its roll-forward moved
    /// past. Cleared when the panel closes — the next glance is about what's still
    /// ahead of you, not what you ticked off last time.
    private var ticked: [UUID: ReminderItem] = [:]

    init(state: AppState, persistsTab: Bool = true) {
        self.state = state
        self.persistsTab = persistsTab
        feed = NotchConnectorFeed(store: state.connectorStore)
        let stored = persistsTab
            ? UserDefaults.standard.string(forKey: NotchQuickActionsTab.defaultsKey)
            : nil
        chosenTab = stored.flatMap(NotchQuickActionsTab.init(storageValue:)) ?? .today
    }

    // MARK: - Tabs

    /// Connections pinned on the Connectors page, in tab order.
    var pinnedConnectors: [ConnectorInstance] { state.connectorStore.pinnedToNotch }

    /// The tab on screen. Opens on the one used last — a person who checks their
    /// mail from the notch wants the mail, not a walk past Today each time.
    var currentTab: NotchQuickActionsTab {
        chosenTab.resolved(pinned: pinnedConnectors.map(\.id))
    }

    func select(_ tab: NotchQuickActionsTab) {
        chosenTab = tab
        if persistsTab {
            UserDefaults.standard.set(tab.storageValue, forKey: NotchQuickActionsTab.defaultsKey)
        }
        if case .connector = tab { feed.refresh(pinnedConnectors) }
    }

    /// Whether the tab bar offers a "+" to pin another connection: there is room
    /// for one, and at least one connection is not pinned yet.
    var canPinMore: Bool {
        let store = state.connectorStore
        return store.canPinToNotch && store.instances.contains { !store.isPinnedToNotch($0.id) }
    }

    /// Take a connection's tab off the band. Pinning happens on the Connectors page,
    /// where the connection is in front of you; the way off has to be here too, for
    /// the same reason a pinned note can be unpinned from the band.
    func unpin(connector id: UUID) {
        state.connectorStore.setPinnedToNotch(id, false)
    }

    /// What the Notes tab holds: pinned first, then recent.
    var notesTabNotes: [Note] {
        notes.visibleNotes.prefix(Self.notesTabLimit).map { $0 }
    }

    /// A connector tab's rows, already windowed to what the tab shows. For a
    /// calendar that is what is still ahead today; the Today tab is where the
    /// morning that has gone lives.
    func connectorContent(_ id: UUID, now: Date = Date()) -> NotchConnectorFeed.Content? {
        guard let content = feed.entry(for: id)?.content else { return nil }
        switch content {
        case .items(let items):
            return .items(Array(items.prefix(NotchConnectorFeed.rowLimit)))
        case .events(let events):
            return .events(Array(events.filter { $0.end > now }.prefix(NotchConnectorFeed.rowLimit)))
        }
    }

    /// Rows the Settings tab draws: two rows of switches and the push-to-talk line.
    static let settingsRowCount = 3

    // MARK: - What the panel holds

    private var notes: NotesStore { state.notesStore }

    private var now: NowStore { state.now }

    /// Today in one ordered column — events and reminders interleaved by time,
    /// what has gone dimmed rather than dropped, windowed onto what is ahead.
    ///
    /// Resolved once per access against a single `Date()`, and the view reads it
    /// once per render into a local, so every row in a given frame agrees about
    /// what "now" is.
    func day(at instant: Date = Date()) -> (rows: [NowTimelineRow], hidden: Int) {
        NowTimeline.window(now.timeline(now: instant, keeping: Set(ticked.keys)))
    }

    /// What the notes column holds: **pinned notes first**, then the most recently
    /// touched, capped at the column limit.
    ///
    /// Pinning is the user's own claim that a note is worth keeping in reach, and
    /// this band is the surface that's always in reach — so a pinned note appears
    /// here rather than only in the window. `NotesStore.visibleNotes` already orders
    /// pinned-then-recent, so the prefix picks them up without a second sort; the
    /// column label changes to say so when any of them are pinned, because a pinned
    /// note under a "recent" heading reads as a coincidence.
    var recentNotes: [Note] {
        notes.visibleNotes.prefix(Self.columnLimit).map { $0 }
    }

    /// Whether the notes column is showing anything pinned — drives its label.
    var showsPinned: Bool {
        recentNotes.contains(where: \.isPinned)
    }

    /// Whether the current page has column captions over its rows — only Today
    /// does. Sizes the band with `NotchQuickActionsLayout.thickness(rows:captioned:)`.
    var isCaptioned: Bool { currentTab == .today }

    /// Rows the current tab is holding — what the band's depth is sized to. Each
    /// tab sizes to itself, so switching from a five-row inbox to a one-line note
    /// list shrinks the band rather than leaving dead black under it.
    var visibleRowCount: Int {
        switch currentTab {
        case .today:
            return max(day().rows.count, recentNotes.count)
        case .notes:
            return max(1, notesTabNotes.count)
        case .connector(let id):
            switch connectorContent(id) {
            case .items(let items)?: return max(1, items.count)
            case .events(let events)?: return max(1, events.count)
            case nil: return 1
            }
        case .settings:
            return Self.settingsRowCount
        }
    }

    /// Unpin a note straight from the band.
    ///
    /// The only note mutation the panel offers, and it's here for the same reason the
    /// reminder checkbox is: it needs no keyboard, and "get this off my notch" is the
    /// one thing a user wants to do to a pinned note *from* the notch. Pinning in the
    /// first place still happens in the window, where the note is in front of them.
    func unpin(_ note: Note) {
        notes.setPinned(note.id, false)
    }

    /// Whether there's an account loaded at all. Signed out, the stores are empty by
    /// design and the panel would be a grid of empty states, so it stays shut.
    var hasAccount: Bool { notes.currentUserID != nil }

    /// Whether a row is showing as ticked off. Read from this glance's own record
    /// rather than from `isCompleted`, because ticking a *repeating* reminder rolls
    /// it to its next occurrence instead of completing it — the box has to stay
    /// checked either way, or the tick reads as having done nothing.
    func isChecked(_ id: UUID) -> Bool { ticked[id] != nil }

    /// Tick a reminder off, or put it back. The undo is why the snapshot is kept:
    /// `completeReminder` isn't a flag flip for a repeat.
    func toggle(_ reminder: ReminderItem) {
        if let snapshot = ticked.removeValue(forKey: reminder.id) {
            notes.restoreReminder(snapshot)
        } else {
            ticked[reminder.id] = reminder
            notes.completeReminder(reminder.id)
        }
    }

    // MARK: - Hover machine

    /// Feed the pointer's position, already resolved to "is it on the thing that
    /// matters" — the notch strip while closed, the panel itself while open. Returns
    /// nothing; read `isOpen` after.
    func pointer(isInside inside: Bool, now: TimeInterval) {
        let wasOpen = gesture.isOpen
        gesture.update(inside: inside, allowed: canOpen, now: now)
        // Opening is the moment the pinned tabs have to be fresh — their badges are
        // on the tab bar whichever tab is showing.
        if gesture.isOpen, !wasOpen { feed.refresh(pinnedConnectors) }
        // The band closing ends the glance, however it closed — pointer away, or a
        // dictation taking the notch back. Ticks stop being undoable at that point,
        // so the completed rows drop out of the list rather than reappearing,
        // struck through, on the next hover.
        if !gesture.isOpen { ticked.removeAll() }
    }

    /// Whether the panel is allowed to open at all. The dictation surface owns the
    /// notch whenever it has something to say, and an empty panel isn't worth the
    /// gesture.
    var canOpen: Bool {
        guard state.quickActionsEnabled else { return false }
        guard hasAccount else { return false }
        guard !state.notchIsOccupied else { return false }
        return true
    }

    /// Close it now — the window calls this when onboarding takes over, on sign-out,
    /// or after an action that opens the Settings window.
    func close() {
        gesture.close()
        ticked.removeAll()
    }
}
