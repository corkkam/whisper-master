import XCTest

@testable import WhisperMaster

/// The notch band a reminder announces itself in, now that the `.notification`
/// alert style lands there instead of Notification Centre. What's locked in here
/// is the *priority* — an alert the user scheduled must not be buried by a
/// passive hint — and the *paused clock*, which is what stops a reminder from
/// expiring unseen behind a dictation.
@MainActor
final class DueReminderBannerTests: XCTestCase {
    private func stateWithDueReminder() -> AppState {
        let state = AppState()
        state.phase = .idle
        state.dueReminder = ReminderItem(title: "Call Migner")
        state.dueReminderAt = Date()
        return state
    }

    func testShowsWhenIdle() {
        let state = stateWithDueReminder()
        XCTAssertTrue(state.canShowDueReminderBanner)
        XCTAssertTrue(state.shouldShowDueReminderBanner)
        XCTAssertTrue(state.notchIsOccupied)
    }

    func testOutranksPassiveHints() {
        let state = stateWithDueReminder()
        // Each of these would show on its own; none may take the band from an
        // alert the user scheduled.
        state.activeReminder = "Dictate something?"
        state.bluetoothInputActive = true
        state.learnedTerm = "Parakeet"
        state.learnedTermAt = Date()
        state.cleanupModelReadyAt = Date()
        state.deliveredAt = Date()

        XCTAssertTrue(state.shouldShowDueReminderBanner)
        XCTAssertFalse(state.shouldShowReminder)
        XCTAssertFalse(state.shouldShowBluetoothBanner)
        XCTAssertFalse(state.shouldShowLearnedBanner)
        XCTAssertFalse(state.shouldShowCleanupReadyBanner)
        XCTAssertFalse(state.shouldShowDeliveredBeat)
    }

    func testYieldsToTheUndeliveredHint() {
        // The undelivered hint carries the only Copy button for text that landed
        // nowhere, so it goes first — and the reminder's clock pauses meanwhile,
        // so it still gets its turn afterwards rather than expiring behind it.
        let state = stateWithDueReminder()
        state.undeliveredText = "Ship the notch reminder today."
        state.undeliveredTranscriptAt = Date()

        XCTAssertTrue(state.shouldShowUndeliveredBanner)
        XCTAssertFalse(state.canShowDueReminderBanner)
        XCTAssertFalse(state.shouldShowDueReminderBanner)
    }

    func testSuppressedButNotExpiredWhileRecording() {
        let state = stateWithDueReminder()
        state.phase = .recording

        XCTAssertFalse(state.canShowDueReminderBanner)
        XCTAssertFalse(state.shouldShowDueReminderBanner)
        // Still queued — the refresh loop holds the window open until the band
        // is free again.
        XCTAssertNotNil(state.dueReminder)
    }

    func testExpiresAfterItsWindow() {
        let state = stateWithDueReminder()
        state.dueReminderAt = Date().addingTimeInterval(-AppState.dueReminderBannerDuration - 1)
        XCTAssertTrue(state.canShowDueReminderBanner)
        XCTAssertFalse(state.shouldShowDueReminderBanner)
    }

    /// Ticking it off swaps the full announcement for the short undo window, so an
    /// answered alert doesn't sit struck-through on the bezel for the rest of it.
    func testTickingItOffShortensTheHoldToTheUndoWindow() {
        let state = stateWithDueReminder()
        XCTAssertEqual(state.dueReminderWindow, AppState.dueReminderBannerDuration)

        state.dueReminderCompleted = true
        XCTAssertEqual(state.dueReminderWindow, AppState.dueReminderAnsweredHold)
        XCTAssertLessThan(AppState.dueReminderAnsweredHold, AppState.dueReminderBannerDuration)

        // Still inside the undo window…
        state.dueReminderAt = Date().addingTimeInterval(-AppState.dueReminderAnsweredHold + 1)
        XCTAssertTrue(state.shouldShowDueReminderBanner)
        // …and gone once it passes, even though the full window hasn't elapsed.
        state.dueReminderAt = Date().addingTimeInterval(-AppState.dueReminderAnsweredHold - 0.1)
        XCTAssertFalse(state.shouldShowDueReminderBanner)
    }
}

/// The two-way half of the notch checkboxes. `completeReminder` isn't a flag flip
/// — a repeat rolls forward instead of completing — so the undo is snapshot-based,
/// and these pin what it must and must not put back.
@MainActor
final class ReminderRestoreTests: XCTestCase {
    private func store() -> NotesStore {
        NotesStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("notes-restore-\(UUID()).json"),
            load: false)
    }

    func testRestoringAnOverdueReminderUnCompletesItWithoutReAlerting() {
        let store = store()
        let reminder = ReminderItem(
            title: "Call Migner",
            dueDate: Date().addingTimeInterval(-60),
            firedAt: Date())
        store.upsertReminder(reminder)
        store.completeReminder(reminder.id)
        XCTAssertTrue(store.visibleReminders[0].isCompleted)

        store.restoreReminder(reminder)
        let back = store.visibleReminders[0]
        XCTAssertFalse(back.isCompleted)
        // It already announced itself — putting it back must not queue it again.
        XCTAssertTrue(store.dueReminders(asOf: Date()).isEmpty)
    }

    /// A reminder ticked off *before* it ever fired is a different case: restoring
    /// it has to leave it able to alert when its time comes.
    func testRestoringAFutureReminderLeavesItArmed() {
        let store = store()
        let due = Date().addingTimeInterval(600)
        let reminder = ReminderItem(title: "Standup", dueDate: due)
        store.upsertReminder(reminder)
        store.completeReminder(reminder.id)
        store.restoreReminder(reminder)

        let back = store.visibleReminders[0]
        XCTAssertFalse(back.isCompleted)
        XCTAssertNil(back.firedAt)
        XCTAssertTrue(back.isDue(asOf: due.addingTimeInterval(1)))
    }

    /// The case the snapshot exists for: ticking a repeat rolls it to the next
    /// occurrence rather than completing it, so an id alone can't undo the tick.
    func testRestoringARepeatPutsBackTheOccurrenceTheRollMovedPast() {
        let store = store()
        let due = Date().addingTimeInterval(-60)
        let reminder = ReminderItem(title: "Standup", dueDate: due, repeatRule: .daily)
        store.upsertReminder(reminder)
        store.completeReminder(reminder.id)

        // Rolled forward, not completed — nothing an `isCompleted = false` undoes.
        XCTAssertFalse(store.visibleReminders[0].isCompleted)
        XCTAssertGreaterThan(store.visibleReminders[0].dueDate, due)

        store.restoreReminder(reminder)
        let back = store.visibleReminders[0]
        XCTAssertEqual(back.dueDate, due)
        XCTAssertEqual(back.repeatRule, .daily)
        XCTAssertTrue(store.dueReminders(asOf: Date()).isEmpty, "restored, not re-announced")
    }
}
