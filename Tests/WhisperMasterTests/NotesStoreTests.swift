import XCTest

@testable import WhisperMaster

@MainActor
final class NotesStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-test-\(UUID()).json")
    }

    // MARK: - Per-user file paths

    func testPerUserFileURLsAreDistinctAndSanitized() {
        let a = NotesStore.fileURL(forUserID: "user_ABC123")
        let b = NotesStore.fileURL(forUserID: "user_XYZ789")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.lastPathComponent, "user_ABC123.json")
        let dirty = NotesStore.fileURL(forUserID: "../../etc/passwd")
        XCTAssertEqual(dirty.lastPathComponent, "______etc_passwd.json")
        XCTAssertFalse(dirty.path.contains(".."))
    }

    // MARK: - Notes CRUD + tombstones

    func testUpsertAndVisibleNotesFilterTombstones() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        let note = Note(title: "Hello", body: "world")
        store.upsertNote(note)
        XCTAssertEqual(store.visibleNotes.count, 1)
        XCTAssertTrue(store.dirtyIDs.contains(note.id))

        store.deleteNote(note.id)
        XCTAssertTrue(store.visibleNotes.isEmpty)          // hidden from the UI
        XCTAssertEqual(store.notes.count, 1)               // tombstone still present
        XCTAssertNotNil(store.notes.first?.deletedAt)
    }

    func testFileRoundTrip() {
        let url = tempURL()
        let store = NotesStore(fileURL: url, load: false)
        let note = Note(title: "Persisted")
        store.upsertNote(note)
        store.upsertReminder(ReminderItem(title: "Ring", dueDate: Date()))

        let reloaded = NotesStore(fileURL: url, load: true)
        XCTAssertEqual(reloaded.notes.count, 1)
        XCTAssertEqual(reloaded.reminders.count, 1)
        XCTAssertEqual(reloaded.notes.first?.title, "Persisted")
    }

    func testPersistenceCanBeDisabled() {
        let url = tempURL()
        let store = NotesStore(fileURL: url, load: false)
        store.persistenceEnabled = false
        store.upsertNote(Note(title: "in-memory only"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testClearDirty() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        let n = Note(title: "x")
        store.upsertNote(n)
        XCTAssertFalse(store.dirtyIDs.isEmpty)
        store.clearDirty([n.id])
        XCTAssertTrue(store.dirtyIDs.isEmpty)
    }

    // MARK: - Reminder firing

    func testDueRemindersRespectsTimeCompletionAndFired() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        let now = Date()

        let past = ReminderItem(title: "past", dueDate: now.addingTimeInterval(-60))
        let future = ReminderItem(title: "future", dueDate: now.addingTimeInterval(600))
        let completed = ReminderItem(title: "done", dueDate: now.addingTimeInterval(-60), isCompleted: true)
        store.upsertReminder(past)
        store.upsertReminder(future)
        store.upsertReminder(completed)

        let due = store.dueReminders(asOf: now)
        XCTAssertEqual(due.map(\.title), ["past"])

        // After firing (non-repeating), it drops out of the due set.
        store.markFired(past.id, at: now)
        XCTAssertTrue(store.dueReminders(asOf: now).isEmpty)
    }

    func testMarkFiredRollsRepeatingReminderForward() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        let now = Date()
        let daily = ReminderItem(title: "daily", dueDate: now.addingTimeInterval(-60), repeatRule: .daily)
        store.upsertReminder(daily)

        store.markFired(daily.id, at: now)
        let rolled = store.reminders.first { $0.id == daily.id }!
        XCTAssertNil(rolled.firedAt)                       // re-armed
        XCTAssertGreaterThan(rolled.dueDate, now)          // rolled to tomorrow
        XCTAssertTrue(store.dueReminders(asOf: now).isEmpty)
    }

    func testCompleteNonRepeatingVsRepeating() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        let once = ReminderItem(title: "once", dueDate: Date())
        let weekly = ReminderItem(title: "weekly", dueDate: Date(), repeatRule: .weekly)
        store.upsertReminder(once)
        store.upsertReminder(weekly)

        store.completeReminder(once.id)
        XCTAssertTrue(store.reminders.first { $0.id == once.id }!.isCompleted)

        store.completeReminder(weekly.id)
        let w = store.reminders.first { $0.id == weekly.id }!
        XCTAssertFalse(w.isCompleted)                      // repeats re-arm, not complete
    }

    // MARK: - Active list vs archive

    func testCompletingMovesAReminderOutOfTheActiveListAndIntoTheArchive() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        let r = ReminderItem(title: "post the form", dueDate: Date())
        store.upsertReminder(r)
        XCTAssertEqual(store.activeReminders.map(\.title), ["post the form"])
        XCTAssertTrue(store.completedReminders.isEmpty)

        store.completeReminder(r.id)
        XCTAssertTrue(store.activeReminders.isEmpty)
        XCTAssertEqual(store.completedReminders.map(\.title), ["post the form"])
        XCTAssertNotNil(store.completedReminders.first?.completedAt)
    }

    func testTheArchiveIsOrderedByWhenThingsWereFinishedNotWhenTheyWereDue() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        // `early` is due long before `late`, so a due-date sort would put it first —
        // but it's finished *second*, and the archive answers "what did I just do".
        let early = ReminderItem(title: "early", dueDate: Date(timeIntervalSinceNow: -86_400))
        let late = ReminderItem(title: "late", dueDate: Date(timeIntervalSinceNow: -60))
        store.upsertReminder(early)
        store.upsertReminder(late)

        store.completeReminder(late.id)
        store.completeReminder(early.id)
        XCTAssertEqual(store.completedReminders.map(\.title), ["early", "late"])
    }

    func testARepeatingReminderRollsForwardInsteadOfBeingArchived() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        let daily = ReminderItem(title: "stand-up", dueDate: Date(), repeatRule: .daily)
        store.upsertReminder(daily)

        store.completeReminder(daily.id)
        XCTAssertEqual(store.activeReminders.map(\.title), ["stand-up"])
        XCTAssertTrue(store.completedReminders.isEmpty)
        // The next occurrence carries no completion stamp — it hasn't been done.
        XCTAssertNil(store.activeReminders.first?.completedAt)
    }

    func testRestoringAnArchivedReminderPutsItBackInTheActiveList() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        let r = ReminderItem(title: "mis-clicked", dueDate: Date(timeIntervalSinceNow: 3_600))
        store.upsertReminder(r)
        store.completeReminder(r.id)

        let archived = store.completedReminders.first!
        store.restoreReminder(archived)
        XCTAssertEqual(store.activeReminders.map(\.title), ["mis-clicked"])
        XCTAssertTrue(store.completedReminders.isEmpty)
        XCTAssertNil(store.activeReminders.first?.completedAt)
    }

    func testClearingCompletedTombstonesThemAndLeavesTheActiveListAlone() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        let done = ReminderItem(title: "done", dueDate: Date())
        let todo = ReminderItem(title: "todo", dueDate: Date(timeIntervalSinceNow: 600))
        store.upsertReminder(done)
        store.upsertReminder(todo)
        store.completeReminder(done.id)

        XCTAssertEqual(store.clearCompletedReminders(), 1)
        XCTAssertTrue(store.completedReminders.isEmpty)
        XCTAssertEqual(store.activeReminders.map(\.title), ["todo"])
        // A tombstone, not a dropped row, so the clear survives a pull-merge.
        XCTAssertNotNil(store.reminders.first { $0.id == done.id }?.deletedAt)
        XCTAssertTrue(store.dirtyIDs.contains(done.id))
        // Idempotent: nothing left to clear.
        XCTAssertEqual(store.clearCompletedReminders(), 0)
    }

    func testSnoozingAnArchivedReminderClearsItsCompletion() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        let r = ReminderItem(title: "later", dueDate: Date())
        store.upsertReminder(r)
        store.completeReminder(r.id)
        store.snoozeReminder(r.id, by: 300)
        XCTAssertTrue(store.completedReminders.isEmpty)
        XCTAssertNil(store.activeReminders.first?.completedAt)
    }

    func testSnoozePushesDueDateOut() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        let r = ReminderItem(title: "snooze me", dueDate: Date().addingTimeInterval(-60))
        store.upsertReminder(r)
        store.snoozeReminder(r.id, by: 300)
        XCTAssertTrue(store.dueReminders(asOf: Date()).isEmpty)
        XCTAssertGreaterThan(store.reminders.first!.dueDate, Date())
    }

    // MARK: - Merge (last-writer-wins + tombstones)

    func testMergeRemoteLastWriterWins() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        let id = UUID()
        let old = Note(id: id, title: "local", updatedAt: Date(timeIntervalSince1970: 1_000))
        store.upsertNote(old)   // upsert restamps updatedAt to now

        // A remote copy strictly newer than the local wins…
        let newer = Note(id: id, title: "remote-new", updatedAt: Date(timeIntervalSinceNow: 60))
        store.mergeRemote(notes: [newer], reminders: [])
        XCTAssertEqual(store.notes.first?.title, "remote-new")

        // …a strictly older remote copy does not.
        let older = Note(id: id, title: "remote-old", updatedAt: Date(timeIntervalSince1970: 1))
        store.mergeRemote(notes: [older], reminders: [])
        XCTAssertEqual(store.notes.first?.title, "remote-new")
    }

    func testMergeRemoteTombstoneWins() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        let id = UUID()
        store.upsertNote(Note(id: id, title: "keep"))
        let remoteDeleted = Note(id: id, title: "keep", updatedAt: Date(timeIntervalSinceNow: 60),
                                 deletedAt: Date(timeIntervalSinceNow: 60))
        store.mergeRemote(notes: [remoteDeleted], reminders: [])
        XCTAssertTrue(store.visibleNotes.isEmpty)
    }

    func testMergeRemoteAddsNewItems() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        store.mergeRemote(notes: [Note(title: "fresh")],
                          reminders: [ReminderItem(title: "fresh-r", dueDate: Date())])
        XCTAssertEqual(store.visibleNotes.count, 1)
        XCTAssertEqual(store.visibleReminders.count, 1)
        // Merged remote items are not re-marked dirty (they came from the server).
        XCTAssertTrue(store.dirtyIDs.isEmpty)
    }

    // MARK: - Activation

    func testActivateAndDeactivateAreScoped() {
        let store = NotesStore(load: false)
        store.activate(userID: "user_a")
        store.upsertNote(Note(title: "a-note"))
        XCTAssertEqual(store.currentUserID, "user_a")

        store.deactivate()
        XCTAssertNil(store.currentUserID)
        XCTAssertTrue(store.notes.isEmpty)                 // dropped from memory

        // Re-activating the same account reloads it from its own file.
        store.activate(userID: "user_a")
        XCTAssertEqual(store.visibleNotes.first?.title, "a-note")

        // Clean up the per-account file this test wrote.
        try? FileManager.default.removeItem(at: NotesStore.fileURL(forUserID: "user_a"))
    }
}
