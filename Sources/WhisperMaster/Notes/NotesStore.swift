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
    func deleteNote(_ id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }), notes[idx].deletedAt == nil else { return }
        notes[idx].deletedAt = Date()
        notes[idx].updatedAt = Date()
        dirtyIDs.insert(id)
        persist()
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
    func completeReminder(_ id: UUID) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        var r = reminders[idx]
        if let next = r.repeatRule.nextDue(after: max(r.dueDate, Date())) {
            r.dueDate = next
            r.firedAt = nil
            r.isCompleted = false
        } else {
            r.isCompleted = true
        }
        r.updatedAt = Date()
        reminders[idx] = r
        dirtyIDs.insert(id)
        persist()
    }

    /// Push a reminder's due date out by `interval` and re-arm it (snooze).
    func snoozeReminder(_ id: UUID, by interval: TimeInterval) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        var r = reminders[idx]
        r.dueDate = Date().addingTimeInterval(interval)
        r.firedAt = nil
        r.isCompleted = false
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

    /// Live notes (tombstones filtered), newest-updated first.
    var visibleNotes: [Note] {
        notes.filter { $0.deletedAt == nil }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Live reminders (tombstones filtered), soonest-due first.
    var visibleReminders: [ReminderItem] {
        reminders.filter { $0.deletedAt == nil }.sorted { $0.dueDate < $1.dueDate }
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
