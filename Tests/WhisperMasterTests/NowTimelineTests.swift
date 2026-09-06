import XCTest

@testable import WhisperMaster

/// The ordered day the hover panel unrolls into.
final class NowTimelineTests: XCTestCase {
    /// Midday, so "today" has room either side of `now` in every time zone the
    /// test machine might be in.
    private let now = Calendar.current.date(
        bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_770_000_000))!

    private func event(_ title: String,
                       startsIn offset: TimeInterval,
                       lasting duration: TimeInterval = 1800,
                       allDay: Bool = false) -> DayEvent {
        DayEvent(
            id: title, title: title,
            start: now.addingTimeInterval(offset),
            end: now.addingTimeInterval(offset + duration),
            isAllDay: allDay,
            calendarTitle: "Work", sourceTitle: "Google", instanceLabel: "Work")
    }

    private func reminder(_ title: String,
                          dueIn offset: TimeInterval,
                          completed: Bool = false) -> ReminderItem {
        ReminderItem(
            title: title, dueDate: now.addingTimeInterval(offset), isCompleted: completed)
    }

    private func rows(_ events: [DayEvent], _ reminders: [ReminderItem],
                      keeping: Set<UUID> = []) -> [NowTimelineRow] {
        NowTimeline.rows(events: events, reminders: reminders, now: now, keeping: keeping)
    }

    // MARK: - Ordering

    func testEventsAndRemindersAreInterleavedByTime() {
        let result = rows(
            [event("Standup", startsIn: -3600), event("Review", startsIn: 3600)],
            [reminder("Ship it", dueIn: 600)])
        XCTAssertEqual(result.map(\.title), ["Standup", "Ship it", "Review"])
    }

    func testAnAllDayEventLeadsWhateverItsClockTimeWouldSay() {
        let result = rows(
            [event("Offsite", startsIn: -11 * 3600, lasting: 86400, allDay: true),
             event("Standup", startsIn: -3600)],
            [])
        XCTAssertEqual(result.first?.title, "Offsite")
    }

    // MARK: - What is past

    func testAFinishedEventIsMarkedPastRatherThanDropped() {
        let result = rows([event("Standup", startsIn: -3600)], [])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isPast)
    }

    func testAnAllDayEventIsNeverPast() {
        // It is true for the whole day, so dimming it at one minute past midnight
        // would say the wrong thing.
        let result = rows(
            [event("Offsite", startsIn: -11 * 3600, lasting: 86400, allDay: true)], [])
        XCTAssertFalse(result[0].isPast)
    }

    // MARK: - Which reminders belong to today

    func testAReminderDueNextWeekIsNotOnToday() {
        let result = rows([], [reminder("Dentist", dueIn: 7 * 86400)])
        XCTAssertTrue(result.isEmpty, "a column headed Today must not hold next week")
    }

    func testAnOverdueReminderFromLastWeekStays() {
        // Being late is the whole reason it is worth the bezel.
        let result = rows([], [reminder("Rotate the key", dueIn: -7 * 86400)])
        XCTAssertEqual(result.map(\.title), ["Rotate the key"])
    }

    func testACompletedReminderIsDroppedUnlessItWasTickedInThisGlance() {
        let done = reminder("Send the note", dueIn: -600, completed: true)
        XCTAssertTrue(rows([], [done]).isEmpty)

        let kept = rows([], [done], keeping: [done.id])
        XCTAssertEqual(kept.map(\.title), ["Send the note"])
        XCTAssertTrue(kept[0].isPast, "a ticked row stays, struck through")
    }

    // MARK: - The window

    func testAShortDayIsShownWhole() {
        let result = NowTimeline.window(rows([event("Review", startsIn: 3600)], []))
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.hidden, 0)
    }

    func testWhatIsAheadWinsTheRoomAndTheRestIsCountedNotDropped() {
        let past = (1...5).map { event("Past \($0)", startsIn: TimeInterval(-$0) * 3600) }
        let ahead = (1...5).map { event("Ahead \($0)", startsIn: TimeInterval($0) * 3600) }
        let result = NowTimeline.window(rows(past + ahead, []))

        XCTAssertEqual(result.rows.count, NowTimeline.displayLimit)
        XCTAssertEqual(result.hidden, 5)
        XCTAssertTrue(
            result.rows.allSatisfy { !$0.isPast },
            "with five things ahead, none of the morning earns a row")
    }

    func testAFinishedDayStillShowsItsTail() {
        let past = (1...8).map { event("Past \($0)", startsIn: TimeInterval(-$0) * 900) }
        let result = NowTimeline.window(rows(past, []))
        XCTAssertEqual(result.rows.count, NowTimeline.displayLimit)
        XCTAssertEqual(result.hidden, 8 - NowTimeline.displayLimit)
        // The most recent, not the earliest: "Past 1" is 15 minutes ago.
        XCTAssertTrue(result.rows.contains { $0.title == "Past 1" })
        XCTAssertFalse(result.rows.contains { $0.title == "Past 8" })
    }

    /// An all-day row sorts first but is never `isPast`, so a window built by
    /// concatenating the two buckets would have dropped it below the finished
    /// morning. The kept rows are re-read out of the original order instead.
    func testTheWindowKeepsTheOriginalOrder() {
        let all = [event("Offsite", startsIn: -11 * 3600, lasting: 86400, allDay: true)]
            + (1...4).map { event("Past \($0)", startsIn: TimeInterval(-$0) * 900) }
            + (1...4).map { event("Ahead \($0)", startsIn: TimeInterval($0) * 900) }
        let result = NowTimeline.window(rows(all, []))
        XCTAssertEqual(result.rows.first?.title, "Offsite")
        XCTAssertEqual(result.rows, result.rows.sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            return lhs.at < rhs.at
        })
    }
}
