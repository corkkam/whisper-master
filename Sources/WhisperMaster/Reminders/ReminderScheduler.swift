import Foundation

/// Drives gentle notch reminders: consulted on each refresh tick, it asks
/// `ReminderPolicy` whether to nudge and, when so, drops a friendly line into
/// the notch via `AppState.activeReminder`, then retracts it after a moment.
///
/// Owned by `DictationViewModel` (the sole legitimate writer of `AppState`), so
/// reminder writes stay funnelled through the view model's collaborator rather
/// than scattered across the app. All timing decisions defer to the pure
/// `ReminderPolicy`; this type only owns the side effects (state mutation,
/// persistence, the dismissal timer).
@MainActor
final class ReminderScheduler {
    private let state: AppState
    private let policy: ReminderPolicy
    private var book: ReminderBookkeeping
    private var dismissWorkItem: DispatchWorkItem?

    init(state: AppState, policy: ReminderPolicy = ReminderPolicy()) {
        self.state = state
        self.policy = policy
        self.book = ReminderBookkeeping.load()
    }

    /// Evaluate whether to show a reminder right now. Cheap; called from the
    /// AppDelegate refresh loop. A no-op unless every gate passes.
    ///
    /// While the feature is off the scheduler stays fully dormant and resets its
    /// cadence, so turning it on later starts a clean idle gap from *that*
    /// moment — never an immediate nudge from stale, pre-opt-in timestamps.
    func tick(now: Date = Date()) {
        guard state.remindersEnabled else {
            clear()
            resetCadenceIfNeeded()
            return
        }

        // First enabled tick starts the clock; the gap is measured from here.
        if book.firstSeenAt == nil {
            book.firstSeenAt = now
            book.save()
        }

        guard state.activeReminder == nil,
              isPoliteMoment,
              policy.shouldNudge(now: now, state: book)
        else { return }

        present(now: now)
    }

    /// Record a completed dictation: resets backoff to the friendly baseline and
    /// clears any reminder currently showing so the live indicator takes over.
    func noteUsed(now: Date = Date()) {
        book.noteUsed(at: now)
        book.save()
        clear()
    }

    /// Retract any showing reminder immediately (e.g. recording is starting).
    func clear() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        if state.activeReminder != nil {
            state.activeReminder = nil
        }
    }

    // MARK: - Internals

    /// While disabled, drop any accumulated cadence so a later opt-in starts
    /// fresh. Guarded so we only write once after a reset, not every tick.
    private func resetCadenceIfNeeded() {
        guard book != ReminderBookkeeping() else { return }
        book = ReminderBookkeeping()
        book.save()
    }

    /// Only nudge while genuinely idle — never over a live indicator, a model
    /// download, or the Bluetooth-mic hint.
    private var isPoliteMoment: Bool {
        state.phase == .idle
            && state.download == nil
            && state.preparingEngine == nil
            && !state.shouldShowBluetoothBanner
    }

    private func present(now: Date) {
        let pick = ReminderCopy.next(after: book.lastLineIndex)
        state.activeReminder = pick.line
        book.noteNudged(at: now, lineIndex: pick.index, dailyWindow: policy.dailyWindow)
        book.save()
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.clear() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + policy.displayDuration,
            execute: work
        )
    }
}
