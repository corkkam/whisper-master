import Foundation

/// Fires due automations.
///
/// openworker's scheduler is a 30-second `asyncio` loop in an always-on server. This is a
/// menu-bar app the user quits, so the loop is the **existing 0.5 s `AppDelegate` refresh
/// tick** — no new timer, no new thread — with a cheap date comparison gating everything.
///
/// Both of openworker's policies are ported deliberately:
///
/// - **run-once-catch-up** — anything that came due while the app was quit fires once on
///   the first tick after launch, then normal cadence resumes. Not once per missed
///   firing: a Mac closed for a week would otherwise produce seven identical digests.
/// - **skip-on-overlap** — a running-id set stops a slow run stacking on itself.
/// - **spawn, don't await** — a run parked on a write approval must never stall the tick
///   or the other automations.
///
/// **Nothing fires while the app is quit.** A `launchd` agent was considered and
/// rejected (a background process the user didn't ask for, a second permissions story,
/// more notarization plumbing), so the UI says so plainly instead of implying otherwise.
@MainActor
final class AutomationScheduler {
    /// Runs one task and returns what happened. Injected so the scheduler's policies are
    /// testable without a model, a network or a store.
    typealias Runner = (ScheduledTask, String) async -> TaskRun

    private let store: AutomationStore
    private let runner: Runner
    private var runningTaskIDs: Set<UUID> = []
    private var hasCaughtUp = false
    /// Guards the tick itself, which is re-entered every 0.5 s.
    private var isTicking = false
    private var now: () -> Date

    init(store: AutomationStore,
         runner: @escaping Runner,
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.runner = runner
        self.now = now
    }

    /// Called from the refresh loop. Cheap when nothing is due, which is almost always.
    func tick() {
        guard !isTicking else { return }
        let trigger = hasCaughtUp ? "schedule" : "catchup"
        hasCaughtUp = true

        let due = store.due(at: now())
        guard !due.isEmpty else { return }

        isTicking = true
        defer { isTicking = false }

        for task in due {
            // Overlap guard first: a task still running is recorded as skipped so the
            // history shows the collision rather than the run silently not happening.
            guard !runningTaskIDs.contains(task.id) else {
                store.complete(TaskRun(taskID: task.id, status: .skipped,
                                       answer: "Previous run was still going.",
                                       trigger: trigger), now: now())
                continue
            }
            runningTaskIDs.insert(task.id)
            // Spawn rather than await — one automation blocked on an approval card must
            // not hold up the tick or any other task.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let run = await self.runner(task, trigger)
                self.runningTaskIDs.remove(task.id)
                self.store.complete(run, now: self.now())
            }
        }
    }

    /// Fire one task now, from the UI. Honours the same overlap guard.
    func runNow(_ task: ScheduledTask) {
        guard !runningTaskIDs.contains(task.id) else { return }
        runningTaskIDs.insert(task.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let run = await self.runner(task, "manual")
            self.runningTaskIDs.remove(task.id)
            self.store.complete(run, now: self.now())
        }
    }

    var isRunning: (UUID) -> Bool {
        { [runningTaskIDs] id in runningTaskIDs.contains(id) }
    }
}
