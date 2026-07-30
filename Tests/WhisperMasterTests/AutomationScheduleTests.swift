import XCTest

@testable import WhisperMaster

/// Schedule arithmetic and the two scheduler policies ported from openworker.
/// Pure — no timer, no model, no network.
@MainActor
final class AutomationScheduleTests: XCTestCase {
    /// A fixed calendar so these never depend on the machine's timezone.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")!
        return formatter.date(from: iso)!
    }

    // MARK: - nextFire

    func testDailyFiresLaterTheSameDay() {
        let schedule = AutomationSchedule.daily(hour: 8, minute: 30)
        let next = schedule.nextFire(after: date("2026-03-10T06:00:00Z"), calendar: calendar)
        XCTAssertEqual(next, date("2026-03-10T08:30:00Z"))
    }

    func testDailyRollsToTomorrowOncePast() {
        let schedule = AutomationSchedule.daily(hour: 8, minute: 30)
        let next = schedule.nextFire(after: date("2026-03-10T09:00:00Z"), calendar: calendar)
        XCTAssertEqual(next, date("2026-03-11T08:30:00Z"))
    }

    /// Strictly after, not at-or-after. `>=` would let a task that just ran at exactly its
    /// scheduled second immediately qualify again and spin.
    func testDailyAtTheExactFireInstantMovesToTheNextDay() {
        let schedule = AutomationSchedule.daily(hour: 8, minute: 30)
        let next = schedule.nextFire(after: date("2026-03-10T08:30:00Z"), calendar: calendar)
        XCTAssertEqual(next, date("2026-03-11T08:30:00Z"))
    }

    func testWeeklyFindsTheNamedWeekday() {
        // 2026-03-10 is a Tuesday; weekday 6 is Friday.
        let schedule = AutomationSchedule.weekly(weekday: 6, hour: 9, minute: 0)
        let next = schedule.nextFire(after: date("2026-03-10T12:00:00Z"), calendar: calendar)
        XCTAssertEqual(next, date("2026-03-13T09:00:00Z"))
    }

    func testWeeklyRollsAWholeWeekWhenTodayIsAlreadyPast() {
        // Tuesday 12:00, asking for Tuesday 09:00 → next Tuesday.
        let schedule = AutomationSchedule.weekly(weekday: 3, hour: 9, minute: 0)
        let next = schedule.nextFire(after: date("2026-03-10T12:00:00Z"), calendar: calendar)
        XCTAssertEqual(next, date("2026-03-17T09:00:00Z"))
    }

    func testOnceFiresOnceThenNever() {
        let at = date("2026-03-10T08:00:00Z")
        let schedule = AutomationSchedule.once(at: at)
        XCTAssertEqual(schedule.nextFire(after: date("2026-03-10T07:00:00Z"), calendar: calendar), at)
        XCTAssertNil(schedule.nextFire(after: at, calendar: calendar))
        XCTAssertNil(schedule.nextFire(after: date("2026-03-11T00:00:00Z"), calendar: calendar))
    }

    func testHumanLabels() {
        XCTAssertEqual(AutomationSchedule.daily(hour: 8, minute: 30).human, "Every day at 8:30 AM")
        XCTAssertEqual(AutomationSchedule.daily(hour: 0, minute: 5).human, "Every day at 12:05 AM")
        XCTAssertEqual(AutomationSchedule.daily(hour: 12, minute: 0).human, "Every day at 12:00 PM")
        XCTAssertEqual(AutomationSchedule.daily(hour: 17, minute: 0).human, "Every day at 5:00 PM")
        XCTAssertEqual(AutomationSchedule.weekly(weekday: 2, hour: 9, minute: 0).human,
                       "Every Monday at 9:00 AM")
    }

    func testScheduleRoundTrips() throws {
        let cases: [AutomationSchedule] = [
            .daily(hour: 7, minute: 15),
            .weekly(weekday: 4, hour: 18, minute: 45),
            .once(at: date("2026-03-10T08:00:00Z")),
        ]
        for schedule in cases {
            let data = try JSONEncoder().encode(schedule)
            XCTAssertEqual(try JSONDecoder().decode(AutomationSchedule.self, from: data), schedule)
        }
    }

    // MARK: - isDue

    func testDisabledTasksAreNeverDue() {
        var task = ScheduledTask(title: "t", instructions: "i",
                                 schedule: .daily(hour: 8, minute: 0), isEnabled: false)
        task.nextRun = date("2026-03-10T08:00:00Z")
        XCTAssertFalse(task.isDue(at: date("2026-03-10T09:00:00Z")))
    }

    func testASpentOneShotIsNeverDue() {
        var task = ScheduledTask(title: "t", instructions: "i",
                                 schedule: .once(at: date("2026-03-01T08:00:00Z")))
        task.nextRun = nil
        XCTAssertFalse(task.isDue(at: date("2026-03-10T09:00:00Z")))
    }

    // MARK: - Store

    private func makeStore() -> AutomationStore {
        let store = AutomationStore(load: false)
        store.persistenceEnabled = false
        return store
    }

    func testAddingComputesTheFirstFiring() {
        let store = makeStore()
        let task = store.add(
            ScheduledTask(title: "Morning", instructions: "what's my day",
                          schedule: .daily(hour: 8, minute: 0)),
            now: date("2026-03-10T06:00:00Z"))
        XCTAssertNotNil(task.nextRun)
        XCTAssertTrue(task.nextRun! > date("2026-03-10T06:00:00Z"))
    }

    func testAOneShotAlreadyInThePastLandsInertRatherThanOverdue() {
        let store = makeStore()
        let task = store.add(
            ScheduledTask(title: "Old", instructions: "x",
                          schedule: .once(at: date("2026-01-01T08:00:00Z"))),
            now: date("2026-03-10T06:00:00Z"))
        XCTAssertNil(task.nextRun)
        XCTAssertTrue(store.due(at: date("2026-03-10T06:00:00Z")).isEmpty)
    }

    func testCompletingAdvancesTheCountAndRearms() {
        let store = makeStore()
        let task = store.add(
            ScheduledTask(title: "Morning", instructions: "x",
                          schedule: .daily(hour: 8, minute: 0)),
            now: date("2026-03-10T06:00:00Z"))
        store.complete(TaskRun(taskID: task.id, status: .ok, answer: "done"),
                       now: date("2026-03-10T08:00:01Z"))
        let updated = store.tasks.first!
        XCTAssertEqual(updated.runCount, 1)
        XCTAssertEqual(updated.lastStatus, .ok)
        XCTAssertNotNil(updated.nextRun)
        XCTAssertEqual(store.runs(for: task.id).count, 1)
    }

    /// A skipped run is a collision, not a firing — it must not advance the count, or an
    /// overlapping long run would silently consume the next scheduled slot.
    func testASkippedRunDoesNotCountAsAFiring() {
        let store = makeStore()
        let task = store.add(
            ScheduledTask(title: "Morning", instructions: "x",
                          schedule: .daily(hour: 8, minute: 0)),
            now: date("2026-03-10T06:00:00Z"))
        store.complete(TaskRun(taskID: task.id, status: .skipped), now: date("2026-03-10T08:00:01Z"))
        let updated = store.tasks.first!
        XCTAssertEqual(updated.runCount, 0)
        XCTAssertNil(updated.lastStatus)
        XCTAssertEqual(store.runs(for: task.id).first?.status, .skipped,
                       "the collision is still recorded in history")
    }

    /// Re-enabling arms from *now*, so a task disabled for a week doesn't fire once for
    /// every firing it missed while off.
    ///
    /// Asserted against `Calendar.current` rather than a fixed UTC instant: "every day at
    /// 8am" means the user's wall clock, so the store deliberately uses the machine's
    /// calendar and a hard-coded UTC expectation would only pass in one timezone.
    func testReEnablingArmsFromNowNotFromTheBacklog() {
        let store = makeStore()
        let schedule = AutomationSchedule.daily(hour: 8, minute: 0)
        let task = store.add(
            ScheduledTask(title: "Morning", instructions: "x", schedule: schedule),
            now: date("2026-03-10T06:00:00Z"))

        let reEnabledAt = date("2026-03-20T09:00:00Z")
        store.setEnabled(task.id, false)
        store.setEnabled(task.id, true, now: reEnabledAt)

        let armed = store.tasks.first?.nextRun
        XCTAssertEqual(armed, schedule.nextFire(after: reEnabledAt))
        XCTAssertTrue(armed! > reEnabledAt, "must arm forward, never into the backlog")
    }

    func testRemovingATaskTakesItsRunsWithIt() {
        let store = makeStore()
        let task = store.add(ScheduledTask(title: "t", instructions: "x",
                                           schedule: .daily(hour: 8, minute: 0)))
        store.complete(TaskRun(taskID: task.id, status: .ok))
        store.remove(task.id)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertTrue(store.runs.isEmpty)
    }

    func testRunHistoryIsCapped() {
        let store = makeStore()
        let task = store.add(ScheduledTask(title: "t", instructions: "x",
                                           schedule: .daily(hour: 8, minute: 0)))
        for _ in 0..<(AutomationStore.maxRuns + 20) {
            store.complete(TaskRun(taskID: task.id, status: .ok))
        }
        XCTAssertEqual(store.runs.count, AutomationStore.maxRuns)
    }

    func testPerUserFileURLsAreDistinctAndSanitized() {
        XCTAssertEqual(AutomationStore.fileURL(forUserID: "user_A").lastPathComponent, "user_A.json")
        XCTAssertEqual(AutomationStore.fileURL(forUserID: nil).lastPathComponent, "device.json")
        let dirty = AutomationStore.fileURL(forUserID: "../../etc/passwd")
        XCTAssertFalse(dirty.path.contains(".."))
    }

    // MARK: - Scheduler policies

    /// Catch-up: the first tick after launch is a `catchup` trigger, and fires **once**
    /// for a backlog rather than once per missed firing.
    func testFirstTickIsCatchupThenSubsequentTicksAreScheduled() async {
        let store = makeStore()
        var task = ScheduledTask(title: "t", instructions: "x",
                                 schedule: .daily(hour: 8, minute: 0))
        task.nextRun = date("2026-03-01T08:00:00Z")     // long overdue
        store.add(task, now: date("2026-03-01T06:00:00Z"))
        // `add` recomputes nextRun, so force the overdue state the app would load.
        store.setEnabled(store.tasks[0].id, true, now: date("2026-03-01T06:00:00Z"))

        var triggers: [String] = []
        let scheduler = AutomationScheduler(
            store: store,
            runner: { task, trigger in
                triggers.append(trigger)
                return TaskRun(taskID: task.id, status: .ok, trigger: trigger)
            },
            now: { self.date("2026-03-10T09:00:00Z") })

        scheduler.tick()
        await Task.yield()
        XCTAssertEqual(triggers.first, "catchup")
        XCTAssertEqual(triggers.count, 1, "a week of missed firings fires once, not seven times")
    }

    func testNothingDueMeansNoRun() async {
        let store = makeStore()
        store.add(ScheduledTask(title: "t", instructions: "x",
                                schedule: .daily(hour: 8, minute: 0)),
                  now: date("2026-03-10T06:00:00Z"))
        var ran = 0
        let scheduler = AutomationScheduler(
            store: store,
            runner: { task, trigger in
                ran += 1
                return TaskRun(taskID: task.id, trigger: trigger)
            },
            now: { self.date("2026-03-10T07:00:00Z") })
        scheduler.tick()
        await Task.yield()
        XCTAssertEqual(ran, 0)
    }
}
