import Foundation
import Observation

/// Drives the hover quick-actions panel: whether it's open, and what the two
/// columns are holding.
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
    /// Most rows a column shows. Past this it stops being a glance.
    static let columnLimit = 3

    var isOpen: Bool { gesture.isOpen }

    private let state: AppState
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

    init(state: AppState) {
        self.state = state
    }

    // MARK: - What the panel holds

    private var notes: NotesStore { state.notesStore }

    /// Live reminders that are still ahead of the user (or overdue and unanswered),
    /// soonest first — the ones worth a glance. Completed ones are done with, bar
    /// any ticked off in this glance, which stay put so they can be un-ticked.
    var reminders: [ReminderItem] {
        notes.visibleReminders
            .filter { !$0.isCompleted || ticked[$0.id] != nil }
            .prefix(Self.columnLimit)
            .map { $0 }
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

    /// Rows in the longer of the two columns — what the band's depth is sized to.
    var visibleRowCount: Int {
        max(reminders.count, recentNotes.count)
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
        gesture.update(inside: inside, allowed: canOpen, now: now)
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
