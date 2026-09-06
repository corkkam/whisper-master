import XCTest

@testable import WhisperMaster

/// What the approval card says. The bug these lock in: the card rendered the
/// router's stamped arguments verbatim — `end: 2026-08-08T09:30:00+05:30 · start:
/// 2026-08-08T09:00:00+05:30 · title: Work · when: tomorrow at nine` under the
/// headline "Add an event to Personal on Personal" — which is three notations of
/// one time under a name said twice, on a band ~390pt wide.
final class ApprovalCopyTests: XCTestCase {
    /// Pinned locale/zone so the rendered clock is the same on every machine.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    /// `DateIntervalFormatter` sets its range with thin spaces around an en dash and
    /// a narrow no-break space before the meridiem. Spelling those out keeps the
    /// expectations exact rather than trading them for a loose `contains`.
    private func range(_ from: String, _ to: String) -> String {
        "\(from)\u{2009}\u{2013}\u{2009}\(to)"
    }

    private static let meridiemSpace = "\u{202F}"

    // MARK: - Headline

    func testTheHeadlineNamesBothWhenTheyDiffer() {
        XCTAssertEqual(
            ApprovalCopy.headline(tool: "send_message", target: "#ops", instanceLabel: "Work"),
            "Post to #ops on Work")
    }

    func testTheHeadlineSaysTheConnectionOnceWhenItIsAlsoTheTarget() {
        XCTAssertEqual(
            ApprovalCopy.headline(
                tool: "create_calendar_event", target: "Personal", instanceLabel: "Personal"),
            "Add an event to Personal")
    }

    /// Labels round-trip through speech, and the grant key compares them
    /// case-insensitively — so the headline must too, or the same name in two cases
    /// reads as two places.
    func testTheHeadlineTreatsCaseAsTheSameName() {
        XCTAssertEqual(
            ApprovalCopy.headline(
                tool: "create_calendar_event", target: "personal", instanceLabel: "Personal"),
            "Add an event to Personal")
    }

    /// An unknown tool still has to say what it will run and where.
    func testAnUnknownToolFallsBackToItsOwnName() {
        XCTAssertEqual(
            ApprovalCopy.headline(tool: "archive_thread", target: "#ops", instanceLabel: "Work"),
            "Run archive_thread on #ops on Work")
    }

    // MARK: - Calendar detail

    func testACalendarWriteReadsAsATitleAndATimeRange() {
        let detail = ApprovalCopy.detail(
            tool: "create_calendar_event",
            arguments: [
                "title": "Work",
                "when": "tomorrow at nine",
                "start": ConnectorHTTP.iso8601(from: date(8, 9)),
                "end": ConnectorHTTP.iso8601(from: date(8, 9, 30)),
                ToolDescriptor.instanceArgument: "Personal",
            ],
            calendar: calendar,
            now: date(8, 7))

        XCTAssertEqual(
            detail,
            "\u{201C}Work\u{201D}  ·  Today "
                + range("9:00", "9:30\(Self.meridiemSpace)AM"))
    }

    func testTomorrowIsNamedRatherThanDated() {
        let detail = ApprovalCopy.detail(
            tool: "create_calendar_event",
            arguments: [
                "title": "Standup",
                "start": ConnectorHTTP.iso8601(from: date(9, 9)),
                "end": ConnectorHTTP.iso8601(from: date(9, 9, 15)),
            ],
            calendar: calendar,
            now: date(8, 7))

        XCTAssertEqual(
            detail,
            "\u{201C}Standup\u{201D}  ·  Tomorrow "
                + range("9:00", "9:15\(Self.meridiemSpace)AM"))
    }

    /// Further out than tomorrow, the day has to be stated — "Friday" alone is
    /// ambiguous once a week is involved.
    func testAFurtherDayCarriesItsDate() {
        let detail = ApprovalCopy.detail(
            tool: "create_calendar_event",
            arguments: [
                "title": "Review",
                "start": ConnectorHTTP.iso8601(from: date(14, 15)),
                "end": ConnectorHTTP.iso8601(from: date(14, 16)),
            ],
            calendar: calendar,
            now: date(8, 7))

        XCTAssertTrue(detail.contains("Aug 14") || detail.contains("14 Aug"), detail)
        XCTAssertTrue(detail.contains("3:00"), detail)
    }

    /// The times are stamped by the router *after* the model's call, so a card can
    /// be built before they exist. The user's own phrase is the honest fallback —
    /// never a date this layer invents.
    func testAnUnstampedCalendarWriteShowsThePhraseTheUserSpoke() {
        let detail = ApprovalCopy.detail(
            tool: "create_calendar_event",
            arguments: ["title": "Work", "when": "tomorrow at nine"],
            calendar: calendar,
            now: date(8, 7))

        XCTAssertEqual(detail, "\u{201C}Work\u{201D}  ·  tomorrow at nine")
    }

    /// The range says how long it runs, so the duration isn't restated — but with
    /// no range to say it, it must not vanish.
    func testTheDurationSurvivesWhenThereIsNoRangeToCarryIt() {
        let detail = ApprovalCopy.detail(
            tool: "create_calendar_event",
            arguments: ["title": "Work", "when": "at nine", "duration_minutes": "45"],
            calendar: calendar,
            now: date(8, 7))

        XCTAssertTrue(detail.contains("duration_minutes: 45"), detail)
    }

    // MARK: - The invariant

    /// **Nothing is hidden.** The card is consent to what will actually run, so an
    /// argument this file doesn't know how to phrase is still shown — raw, the way
    /// the whole card used to look — rather than dropped. A new argument on an
    /// existing tool must degrade, not disappear.
    func testAnUnrecognisedArgumentIsStillShown() {
        let detail = ApprovalCopy.detail(
            tool: "create_calendar_event",
            arguments: [
                "title": "Work",
                "start": ConnectorHTTP.iso8601(from: date(8, 9)),
                "end": ConnectorHTTP.iso8601(from: date(8, 9, 30)),
                "invitees": "sam@example.com",
            ],
            calendar: calendar,
            now: date(8, 7))

        XCTAssertTrue(detail.contains("invitees: sam@example.com"), detail)
    }

    func testAnUnknownToolShowsItsWholePayloadRaw() {
        let detail = ApprovalCopy.detail(
            tool: "archive_thread",
            arguments: ["thread": "42", ToolDescriptor.instanceArgument: "Work"],
            calendar: calendar,
            now: date(8, 7))

        XCTAssertEqual(detail, "thread: 42")
    }

    /// A card with nothing to say still has to ask the question.
    func testAnEmptyPayloadStillAsks() {
        XCTAssertEqual(
            ApprovalCopy.detail(tool: "send_message", arguments: [:],
                                calendar: calendar, now: date(8, 7)),
            "Approve this action?")
    }
}
