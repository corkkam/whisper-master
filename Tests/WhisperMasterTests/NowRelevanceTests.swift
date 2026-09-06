import XCTest

@testable import WhisperMaster

/// The ambient notch row's relevance ladder. Pure and clock-injected, so the
/// horizons are pinned here rather than discovered by waiting for a meeting.
final class NowRelevanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func event(_ title: String,
                       startsIn offset: TimeInterval,
                       lasting duration: TimeInterval = 1800,
                       allDay: Bool = false,
                       join: String? = nil) -> DayEvent {
        DayEvent(
            id: title, title: title,
            start: now.addingTimeInterval(offset),
            end: now.addingTimeInterval(offset + duration),
            isAllDay: allDay,
            calendarTitle: "Work", sourceTitle: "Google",
            instanceLabel: "Work",
            joinURL: join.flatMap(URL.init(string:)))
    }

    private func reminder(_ title: String,
                          dueIn offset: TimeInterval,
                          completed: Bool = false) -> ReminderItem {
        ReminderItem(
            title: title, dueDate: now.addingTimeInterval(offset), isCompleted: completed)
    }

    // MARK: - The ordering

    func testNothingInsideAHorizonLeavesTheNotchDark() {
        let item = NowRelevance.pick(
            events: [event("Retro", startsIn: 5 * 3600)],
            reminders: [reminder("Later", dueIn: 4 * 3600)],
            now: now)
        XCTAssertNil(item)
    }

    func testAMeetingInProgressOutranksEverything() {
        let item = NowRelevance.pick(
            events: [event("Standup", startsIn: -300), event("Review", startsIn: 120)],
            reminders: [reminder("Late thing", dueIn: -600)],
            now: now)
        XCTAssertEqual(item?.title, "Standup")
        XCTAssertEqual(item?.kind, .meetingNow)
    }

    func testTheMostRecentlyStartedMeetingWins() {
        // A short standup inside a long focus block is the one you are in.
        let item = NowRelevance.pick(
            events: [
                event("Focus", startsIn: -3600, lasting: 7200),
                event("Standup", startsIn: -120, lasting: 900),
            ],
            reminders: [], now: now)
        XCTAssertEqual(item?.title, "Standup")
    }

    func testAnImminentMeetingOutranksAnOverdueReminder() {
        let item = NowRelevance.pick(
            events: [event("Review", startsIn: 5 * 60)],
            reminders: [reminder("Rotate the key", dueIn: -3600)],
            now: now)
        XCTAssertEqual(item?.kind, .meetingSoon)
    }

    func testAnOverdueReminderOutranksTheQuietLookAhead() {
        let item = NowRelevance.pick(
            events: [event("Review", startsIn: 40 * 60)],
            reminders: [reminder("Rotate the key", dueIn: -60)],
            now: now)
        XCTAssertEqual(item?.kind, .reminderOverdue)
        XCTAssertEqual(item?.title, "Rotate the key")
    }

    func testTheOldestOverdueReminderIsTheOneShown() {
        let item = NowRelevance.pick(
            events: [],
            reminders: [reminder("Yesterday", dueIn: -86400), reminder("An hour ago", dueIn: -3600)],
            now: now)
        XCTAssertEqual(item?.title, "Yesterday")
    }

    func testTheQuietLookAheadIsTheLastRung() {
        let item = NowRelevance.pick(
            events: [event("Review", startsIn: 40 * 60)], reminders: [], now: now)
        XCTAssertEqual(item?.kind, .nextEvent)
    }

    // MARK: - Horizons

    func testAMeetingJustOutsideItsHorizonIsNotUrgentYet() {
        let item = NowRelevance.pick(
            events: [event("Review", startsIn: NowRelevance.meetingHorizon + 60)],
            reminders: [], now: now)
        XCTAssertEqual(item?.kind, .nextEvent, "past 10 minutes it is orientation, not news")
    }

    func testAnEventBeyondTheLookAheadIsNotShownAtAll() {
        let item = NowRelevance.pick(
            events: [event("Review", startsIn: NowRelevance.lookahead + 60)],
            reminders: [], now: now)
        XCTAssertNil(item)
    }

    func testAReminderInsideItsHorizonIsShown() {
        let item = NowRelevance.pick(
            events: [],
            reminders: [reminder("Ship it", dueIn: NowRelevance.reminderHorizon - 60)],
            now: now)
        XCTAssertEqual(item?.kind, .reminderSoon)
    }

    // MARK: - Exclusions

    func testAnAllDayEventNeverBecomesTheAmbientItem() {
        // It has no moment to count down to, so "in 6m" would be a lie about
        // something that is true for sixteen hours.
        let item = NowRelevance.pick(
            events: [event("Company offsite", startsIn: -3600, lasting: 86400, allDay: true)],
            reminders: [], now: now)
        XCTAssertNil(item)
    }

    func testACompletedReminderIsNotShown() {
        let item = NowRelevance.pick(
            events: [],
            reminders: [reminder("Done already", dueIn: -600, completed: true)],
            now: now)
        XCTAssertNil(item)
    }

    // MARK: - What the item carries

    func testAMeetingCarriesItsJoinLinkAndAReminderCarriesItsID() {
        let meeting = NowRelevance.pick(
            events: [event("Review", startsIn: 120, join: "https://acme.zoom.us/j/1")],
            reminders: [], now: now)
        XCTAssertEqual(meeting?.joinURL?.absoluteString, "https://acme.zoom.us/j/1")
        XCTAssertNil(meeting?.reminderID)

        let due = reminder("Rotate the key", dueIn: -60)
        let late = NowRelevance.pick(events: [], reminders: [due], now: now)
        XCTAssertEqual(late?.reminderID, due.id)
        XCTAssertNil(late?.joinURL)
    }

    // MARK: - Wording

    func testTheCountdownIsWholeMinutesRoundedUp() {
        // Rounded up, so a meeting thirty seconds away is never "in 0m".
        XCTAssertEqual(NowPhrase.relative(30), "1m")
        XCTAssertEqual(NowPhrase.relative(6 * 60), "6m")
        XCTAssertEqual(NowPhrase.relative(6 * 60 + 1), "7m")
    }

    func testPastNinetyMinutesTheCountdownSwitchesToHours() {
        XCTAssertEqual(NowPhrase.relative(90 * 60), "90m")
        XCTAssertEqual(NowPhrase.relative(118 * 60), "2h")
    }

    func testAMeetingInProgressSaysNowAndALateReminderSaysOverdue() {
        let running = NowRelevance.pick(
            events: [event("Standup", startsIn: -120)], reminders: [], now: now)
        XCTAssertEqual(NowPhrase.moment(for: running!, now: now), "now")

        let late = NowRelevance.pick(
            events: [], reminders: [reminder("Rotate", dueIn: -600)], now: now)
        XCTAssertEqual(NowPhrase.moment(for: late!, now: now), "overdue")
    }

    /// The band is measured against this string, so it has to cover everything the
    /// row actually draws — the marker, and the Join pill when there is one.
    func testTheSizingLabelChargesMoreWhenThereIsAJoinPill() {
        let plain = NowRelevance.pick(
            events: [event("Review", startsIn: 120)], reminders: [], now: now)!
        let joinable = NowRelevance.pick(
            events: [event("Review", startsIn: 120, join: "https://acme.zoom.us/j/1")],
            reminders: [], now: now)!
        XCTAssertGreaterThan(
            NotchNowRow.sizingLabel(joinable, now: now).count,
            NotchNowRow.sizingLabel(plain, now: now).count)
    }

    /// A Join pill is only offered for something you can actually walk into.
    func testTheLookAheadRungIsNeverJoinable() {
        let ahead = NowRelevance.pick(
            events: [event("Review", startsIn: 40 * 60, join: "https://acme.zoom.us/j/1")],
            reminders: [], now: now)!
        XCTAssertEqual(ahead.kind, .nextEvent)
        XCTAssertFalse(NotchNowRow.isJoinable(ahead))
    }
}
