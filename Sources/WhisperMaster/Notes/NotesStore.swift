import Foundation
import Observation

/// Durable, on-device store for a signed-in account's notes and reminders — the
/// source of truth behind the Notes & Reminders settings tab.
///
/// Modeled directly on `UsageStore`: per-account file, idempotent `activate` /
/// `deactivate` for the auth reconcile tick, a single set of mutators that stamp
/// `updatedAt` + mark items dirty + persist, and a `dirtyIDs` set that
/// `NotesSyncClient` drains to the dashboard. Local is always the source of
/// truth; sync is a best-effort backup + cross-device catch-up.
///
/// Soft deletes (a `deletedAt` tombstone rather than dropping the row) so a
/// delete on one Mac survives a pull-merge from another instead of being
/// resurrected by the remote copy.
@MainActor
@Observable
final class NotesStore {
    private(set) var notes: [Note] = []
    private(set) var reminders: [ReminderItem] = []
    /// Item ids (note or reminder) changed since the last successful sync.
    private(set) var dirtyIDs: Set<UUID> = []

    /// The signed-in account whose data is loaded, or nil before first sign-in /
    /// after sign-out. Everything here is scoped to it.
    private(set) var currentUserID: String?

    private var fileURL: URL

    /// When false, mutators fold into memory but never write to disk — set by the
    /// headless snapshot renderer so seeded mock data can't clobber a real file.
    var persistenceEnabled = true

    init(fileURL: URL = NotesStore.defaultFileURL, load: Bool = true) {
        self.fileURL = fileURL
        if load { loadFromDisk() }
    }

    /// Pre-sign-in / test default path. Real data lives in the per-user file.
    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WhisperMaster/Notes/_local.json", isDirectory: false)
    }

    /// Per-account file `…/WhisperMaster/Notes/<userId>.json`. The id is sanitized
    /// so it's always a safe filename (never trust an id straight into a path).
    nonisolated static func fileURL(forUserID userID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safe = String(userID.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return base.appendingPathComponent("WhisperMaster/Notes/\(safe).json", isDirectory: false)
    }

    // MARK: - Per-user activation

    /// Scope the store to `userID`: repoint the file and reload. Idempotent — a
    /// no-op when already scoped there, so the 0.5s auth reconcile tick can call
    /// it freely. Each account starts fresh; a later `mergeRemote` pulls the
    /// cloud copy in.
    func activate(userID: String) {
        guard !userID.isEmpty, userID != currentUserID else { return }
        currentUserID = userID
        fileURL = Self.fileURL(forUserID: userID)
        notes = []
        reminders = []
        dirtyIDs = []
        loadFromDisk()
    }

    /// Drop the loaded account on sign-out. The file stays on disk for their return.
    func deactivate() {
        guard currentUserID != nil else { return }
        currentUserID = nil
        fileURL = Self.defaultFileURL
        notes = []
        reminders = []
        dirtyIDs = []
    }

    // MARK: - Notes mutators

    /// Insert or replace a note (matched by id), stamping `updatedAt`, marking it
    /// dirty, and persisting. The single write path for notes.
    func upsertNote(_ note: Note) {
        var updated = note
        updated.updatedAt = Date()
        if let idx = notes.firstIndex(where: { $0.id == note.id }) {
            notes[idx] = updated
        } else {
            notes.append(updated)
        }
        dirtyIDs.insert(updated.id)
        persist()
    }

    /// Soft-delete a note (tombstone) so the delete syncs.
    ///
    /// The *row* is kept as a tombstone, but the recording is deleted outright —
    /// it's the biggest thing the app writes and it isn't synced, so there is
    /// nothing for another Mac to reconcile and no reason to keep megabytes of
    /// audio for a note the user threw away.
    func deleteNote(_ id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }), notes[idx].deletedAt == nil else { return }
        NoteAudioStore.delete(notes[idx].audio)
        notes[idx].audio = nil
        notes[idx].deletedAt = Date()
        notes[idx].updatedAt = Date()
        // A deleted note must not keep haunting the canvas or the notch band.
        notes[idx].isPinned = false
        dirtyIDs.insert(id)
        persist()
        Analytics.shared.send(.noteDeleted)
    }

    /// Pin or unpin a note. Pinned notes lead the canvas and are the ones the notch
    /// band shows, so this is the one note mutation reachable from the bezel.
    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let idx = notes.firstIndex(where: { $0.id == id }), notes[idx].isPinned != pinned else { return }
        notes[idx].isPinned = pinned
        notes[idx].updatedAt = Date()
        dirtyIDs.insert(id)
        persist()
        // Instrumented here rather than at the call sites: pinning is reachable
        // from the canvas, the quick-actions column and the notch, and a signal
        // wired per surface would quietly miss whichever one gets added next.
        // The guard above means this only fires on a real change, never on a
        // redundant set.
        Analytics.shared.send(.notePinned(pinned: pinned))
    }

    // MARK: - Reminder mutators

    func upsertReminder(_ reminder: ReminderItem) {
        var updated = reminder
        updated.updatedAt = Date()
        if let idx = reminders.firstIndex(where: { $0.id == reminder.id }) {
            reminders[idx] = updated
        } else {
            reminders.append(updated)
        }
        dirtyIDs.insert(updated.id)
        persist()
    }

    func deleteReminder(_ id: UUID) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }), reminders[idx].deletedAt == nil else { return }
        reminders[idx].deletedAt = Date()
        reminders[idx].updatedAt = Date()
        dirtyIDs.insert(id)
        persist()
    }

    /// Mark a reminder done (or, if it repeats, roll it to its next occurrence and
    /// re-arm it instead of completing).
    ///
    /// A completed reminder is stamped with `completedAt` — that stamp is what
    /// orders the archive, and it's the only record of *when* the work was
    /// finished, since `dueDate` keeps answering when it was meant to be.
    func completeReminder(_ id: UUID) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        var r = reminders[idx]
        if let next = r.repeatRule.nextDue(after: max(r.dueDate, Date())) {
            r.dueDate = next
            r.firedAt = nil
            r.isCompleted = false
            // The next occurrence hasn't been done, so it carries no completion
            // stamp — leaving a stale one would put a live reminder in the archive
            // order if it were ever ticked into it.
            r.completedAt = nil
        } else {
            r.isCompleted = true
            r.completedAt = Date()
        }
        r.updatedAt = Date()
        reminders[idx] = r
        dirtyIDs.insert(id)
        persist()
        // A repeat rolled forward and a one-off archived are different outcomes of
        // the same tap, and the copy promises the difference up front — so they
        // stay separable in the reports too. `isCompleted` is false on the repeat
        // branch precisely because it was re-armed, which is what distinguishes
        // them here.
        Analytics.shared.send(.reminderCompleted(repeating: !r.isCompleted))
    }

    /// Put a reminder back the way it was before it was ticked off — the undo half
    /// of the notch checkboxes, which let a user un-check as well as check.
    ///
    /// It takes the pre-tick **snapshot** rather than an id because
    /// `completeReminder` isn't a flag flip: a repeating reminder rolls forward to
    /// its next occurrence instead of completing, and only the caller that ticked
    /// it still holds the occurrence that was rolled away. Restoring the snapshot
    /// puts date, repeat state and completion back in one move.
    ///
    /// The one field that is *not* restored is `firedAt` on an already-due
    /// reminder: the alert has happened (that band is what the user is un-ticking),
    /// so it's stamped as fired to stop the poll loop announcing it a second time.
    /// A reminder still in the future keeps its `firedAt` and alerts normally when
    /// its time comes.
    func restoreReminder(_ snapshot: ReminderItem) {
        var r = snapshot
        r.isCompleted = false
        r.completedAt = nil
        if r.dueDate <= Date() { r.firedAt = Date() }
        upsertReminder(r)
        // An un-tick is the strongest available evidence that a checkbox is in the
        // wrong place or too easy to hit by accident, so it is worth counting
        // against the completions above rather than being invisible.
        Analytics.shared.send(.reminderRestored)
    }

    /// Empty the archive: soft-delete every completed reminder in one move.
    ///
    /// Tombstones rather than dropped rows, like every other delete here, so
    /// clearing on one Mac doesn't get undone by a pull-merge from another.
    /// Returns how many were cleared so the caller can say so.
    @discardableResult
    func clearCompletedReminders() -> Int {
        let now = Date()
        var cleared = 0
        for idx in reminders.indices where reminders[idx].isCompleted && reminders[idx].deletedAt == nil {
            reminders[idx].deletedAt = now
            reminders[idx].updatedAt = now
            dirtyIDs.insert(reminders[idx].id)
            cleared += 1
        }
        if cleared > 0 {
            persist()
            Analytics.shared.send(.reminderArchiveCleared)
        }
        return cleared
    }

    /// Push a reminder's due date out by `interval` and re-arm it (snooze).
    func snoozeReminder(_ id: UUID, by interval: TimeInterval) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        var r = reminders[idx]
        r.dueDate = Date().addingTimeInterval(interval)
        r.firedAt = nil
        r.isCompleted = false
        r.completedAt = nil
        r.updatedAt = Date()
        reminders[idx] = r
        dirtyIDs.insert(id)
        persist()
    }

    /// Record that a reminder just fired (so the poll loop alerts it once). For a
    /// repeating reminder this also rolls the due date to the next occurrence and
    /// clears `firedAt`, so it re-arms automatically.
    func markFired(_ id: UUID, at when: Date = Date()) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        var r = reminders[idx]
        if let next = r.repeatRule.nextDue(after: max(r.dueDate, when)) {
            r.dueDate = next
            r.firedAt = nil
        } else {
            r.firedAt = when
        }
        r.updatedAt = Date()
        reminders[idx] = r
        dirtyIDs.insert(id)
        persist()
    }

    // MARK: - Queries

    /// Live notes (tombstones filtered), **pinned first**, then newest-updated.
    ///
    /// Pinning is a claim about importance, so it outranks recency everywhere the
    /// notes are listed — the canvas, the notch band, and the quick-actions column
    /// all read this one order rather than each inventing their own.
    var visibleNotes: [Note] {
        notes
            .filter { $0.deletedAt == nil }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    /// Just the pinned notes, in the same order — what the canvas floats to the top
    /// and what the notch band shows.
    var pinnedNotes: [Note] {
        visibleNotes.filter(\.isPinned)
    }

    /// Live, unpinned notes — the tail of the canvas below the pinned row.
    var unpinnedNotes: [Note] {
        visibleNotes.filter { !$0.isPinned }
    }

    /// Live reminders (tombstones filtered), soonest-due first — **both halves**,
    /// done and not. Almost every caller wants `activeReminders` instead; this stays
    /// for the places that legitimately need the whole set (sync, tests).
    var visibleReminders: [ReminderItem] {
        reminders.filter { $0.deletedAt == nil }.sorted { $0.dueDate < $1.dueDate }
    }

    /// What's still to do, soonest-due first — the list every surface shows.
    ///
    /// Split from the archive because a due-date-ordered list holding both answers
    /// neither question: a reminder finished this morning sorts above one due
    /// tonight, so "what's left?" stops being readable at a glance the moment
    /// anything gets ticked off. A repeating reminder is never completed (it rolls
    /// forward), so it lives here permanently.
    var activeReminders: [ReminderItem] {
        visibleReminders.filter { !$0.isCompleted }
    }

    /// The archive: finished reminders, **most recently finished first**.
    ///
    /// Recency, not due date — the archive is looked at to confirm something just
    /// got done (and to undo a mis-tick), and both of those are about the last few
    /// minutes rather than about when the thing was originally scheduled.
    var completedReminders: [ReminderItem] {
        reminders
            .filter { $0.deletedAt == nil && $0.isCompleted }
            .sorted { $0.archivedAt > $1.archivedAt }
    }

    /// Reminders that should alert as of `now` (due, not fired for this
    /// occurrence, not completed/deleted).
    func dueReminders(asOf now: Date = Date()) -> [ReminderItem] {
        reminders.filter { $0.isDue(asOf: now) }
    }

    // MARK: - Sync merge (pull side, last-writer-wins by updatedAt)

    /// Fold remote copies into the local store. For each id, the copy with the
    /// newer `updatedAt` wins (tombstones included, so a remote delete sticks).
    /// New remote ids are added; unchanged locals are left alone. Merged items
    /// are NOT re-marked dirty (they came from the server).
    func mergeRemote(notes remoteNotes: [Note], reminders remoteReminders: [ReminderItem]) {
        var changed = false

        for remote in remoteNotes {
            if let idx = notes.firstIndex(where: { $0.id == remote.id }) {
                if remote.updatedAt > notes[idx].updatedAt {
                    notes[idx] = remote
                    changed = true
                }
            } else {
                notes.append(remote)
                changed = true
            }
        }

        for remote in remoteReminders {
            if let idx = reminders.firstIndex(where: { $0.id == remote.id }) {
                if remote.updatedAt > reminders[idx].updatedAt {
                    reminders[idx] = remote
                    changed = true
                }
            } else {
                reminders.append(remote)
                changed = true
            }
        }

        if changed { persist() }
    }

    /// Notes + reminders for a set of ids — the sync payload source.
    func dirtyItems() -> (notes: [Note], reminders: [ReminderItem]) {
        (notes.filter { dirtyIDs.contains($0.id) },
         reminders.filter { dirtyIDs.contains($0.id) })
    }

    /// Called by the sync client after a successful push so those ids stop
    /// re-uploading (they re-dirty the moment they change again).
    func clearDirty(_ ids: Set<UUID>) {
        dirtyIDs.subtract(ids)
        persist()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var notes: [Note]
        var reminders: [ReminderItem]
        var dirtyIDs: [UUID]
    }

    private func persist() {
        guard persistenceEnabled else { return }
        let snapshot = Snapshot(notes: notes, reminders: reminders, dirtyIDs: Array(dirtyIDs))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            Log.notes.error("notes persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
        notes = snapshot.notes
        reminders = snapshot.reminders
        dirtyIDs = Set(snapshot.dirtyIDs)
    }
}
