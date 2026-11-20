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

    // MARK: - The warning after a read

    private func card(grantOffered: Bool) -> PendingApproval {
        PendingApproval(tool: "send_message", instanceID: UUID(), instanceLabel: "Work",
                        target: "#general",
                        arguments: ["channel": "#general", "text": "I quit."],
                        grantOffered: grantOffered)
    }

    /// The warning rides on the same signal that hides Always, so a card can never
    /// offer a grant and warn, or warn on a run that read nothing.
    func testTheWarningShowsExactlyWhenNoGrantIsOffered() {
        XCTAssertEqual(card(grantOffered: false).readWarning, ApprovalCopy.readWarning)
        XCTAssertNil(card(grantOffered: true).readWarning)
        // The default is the untainted card.
        XCTAssertNil(PendingApproval(tool: "send_message", instanceID: UUID(),
                                     instanceLabel: "Work", target: "#general",
                                     arguments: [:]).readWarning)
    }

    /// The warning adds a line; the payload stays whole beside it.
    func testTheWarningDoesNotShortenThePayload() {
        XCTAssertEqual(card(grantOffered: false).detail, card(grantOffered: true).detail)
    }

    /// A screen-reader user hears the warning on exactly the cards that show it.
    @MainActor
    func testVoiceOverReadsTheWarningOnlyWhenItIsShown() {
        let warned = NotchApprovalBanner(approval: card(grantOffered: false)) { _ in }
        let plain = NotchApprovalBanner(approval: card(grantOffered: true)) { _ in }
        XCTAssertTrue(warned.accessibilityText.contains(ApprovalCopy.readWarning))
        XCTAssertTrue(warned.accessibilityText.contains("I quit."))
        XCTAssertFalse(plain.accessibilityText.contains(ApprovalCopy.readWarning))
    }

    /// The band's height is decided before the card lays out, so the warned card
    /// must get the extra line up front, and the panel (sized once, at window
    /// creation) must fit it, or the card is clipped by its own window.
    func testTheWarnedCardGetsATallerBandThatThePanelFits() {
        let layout = NotchSurfaceLayout()
        let banner = layout.bannerThickness
        XCTAssertEqual(NotchApprovalBanner.thickness(for: card(grantOffered: true), banner: banner),
                       banner)
        let warned = NotchApprovalBanner.thickness(for: card(grantOffered: false), banner: banner)
        XCTAssertEqual(warned, banner + NotchApprovalBanner.warningLineHeight)
        let geometry = NotchGeometry(notchWidth: 200, notchHeight: 37.5, screenWidth: 1512)
        XCTAssertLessThanOrEqual(warned, layout.panelSize(for: geometry).height - geometry.notchHeight)
    }

    // MARK: - This Mac (device tools)

    private func linkCard(_ url: String, tainted: Bool = false) -> PendingApproval {
        PendingApproval(tool: "open_url", instanceID: DeviceToolCatalog.thisMacID,
                        instanceLabel: DeviceToolCatalog.thisMacLabel, target: url,
                        arguments: ["url": url], grantOffered: !tainted, grantable: false)
    }

    func testAnAppCardNamesTheAppOnThisMac() {
        XCTAssertEqual(ApprovalCopy.verb(for: "open_app"), "Open")
        XCTAssertEqual(
            ApprovalCopy.headline(tool: "open_app", target: "Figma", instanceLabel: "This Mac"),
            "Open Figma on This Mac")
        XCTAssertEqual(ApprovalCopy.detail(tool: "open_app", arguments: ["app": "Figma"]),
                       ApprovalCopy.openAppDetail)
    }

    /// The host leads, because it is the part that decides; the whole link follows,
    /// because a card that hides part of the payload is not consent to it.
    func testALinkCardNamesTheHostAndCarriesTheWholeLink() {
        let url = "https://github.com/settings/tokens?scope=repo"
        XCTAssertEqual(ApprovalCopy.headline(tool: "open_url", target: url, instanceLabel: "This Mac"),
                       "Open github.com in your browser")
        XCTAssertEqual(ApprovalCopy.detail(tool: "open_url", arguments: ["url": url]), url)
    }

    /// "No Always" is a property of the tool, not of the run, so it must not bring
    /// the after-reading warning with it.
    func testALinkNeverOffersAlwaysAndWarnsOnlyWhenTainted() {
        XCTAssertFalse(linkCard("https://github.com").offersAlways)
        XCTAssertNil(linkCard("https://github.com").readWarning)
        XCTAssertNotNil(linkCard("https://github.com", tainted: true).readWarning)
        XCTAssertTrue(card(grantOffered: true).offersAlways, "a connector card is unchanged")
    }

    /// A long link wraps rather than truncates, so its card is taller — and still
    /// inside the panel, which is sized once.
    func testALongLinkGetsTheLinesItNeedsInsideThePanel() {
        let layout = NotchSurfaceLayout()
        let banner = layout.bannerThickness
        XCTAssertEqual(NotchApprovalBanner.thickness(for: linkCard("https://github.com"), banner: banner),
                       banner)
        let longest = "https://example.com/" + String(
            repeating: "a", count: DeviceToolCatalog.maxURLLength - "https://example.com/".count)
        let tall = NotchApprovalBanner.thickness(for: linkCard(longest, tainted: true), banner: banner)
        XCTAssertGreaterThan(tall, banner + NotchApprovalBanner.warningLineHeight)
        let geometry = NotchGeometry(notchWidth: 200, notchHeight: 37.5, screenWidth: 1512)
        XCTAssertLessThanOrEqual(tall, layout.panelSize(for: geometry).height - geometry.notchHeight)
    }

    // MARK: - A note or a reminder after a read

    private func localCard(_ tool: String, _ arguments: [String: String]) -> PendingApproval {
        PendingApproval(tool: tool, instanceID: DeviceToolCatalog.thisMacID,
                        instanceLabel: DeviceToolCatalog.thisMacLabel,
                        target: DeviceToolCatalog.thisMacLabel,
                        arguments: arguments, grantOffered: false, grantable: false)
    }

    func testANoteCardShowsTheTitleAndTheWholeBody() {
        let body = "Dana says the launch moved to Friday and the deck needs the new pricing slide"
        let card = localCard("create_note", ["title": "Launch", "body": body])
        XCTAssertEqual(card.headline, "Save a note on This Mac")
        XCTAssertEqual(card.detail, "\u{201C}Launch\u{201D}  ·  \u{201C}\(body)\u{201D}")
        XCTAssertEqual(card.readWarning, ApprovalCopy.readWarning)
        XCTAssertFalse(card.offersAlways)
    }

    /// The card states the time the app resolved and will save, never the phrase.
    func testAReminderCardShowsTheResolvedTimeNotThePhrase() {
        let detail = ApprovalCopy.detail(
            tool: "create_reminder",
            arguments: ["title": "Call the bank", "due": ConnectorHTTP.iso8601(from: date(9, 9)),
                        "body": "Ask about the fee"],
            calendar: calendar,
            now: date(8, 7))

        XCTAssertTrue(detail.hasPrefix("\u{201C}Call the bank\u{201D}  ·  Tomorrow 9:00"), detail)
        XCTAssertTrue(detail.hasSuffix("AM  ·  \u{201C}Ask about the fee\u{201D}"), detail)
        XCTAssertFalse(detail.contains("due"), "the stamp is presented, not shown raw")
        XCTAssertEqual(ApprovalCopy.headline(tool: "create_reminder", target: "This Mac",
                                             instanceLabel: "This Mac"),
                       "Set a reminder on This Mac")
    }

    /// The longest note the runner lets through wraps onto lines the band reserves,
    /// inside the panel, which is sized once.
    func testTheLongestNoteCardFitsThePanel() {
        let body = String(repeating: "a", count: ApprovalCopy.maxWrappedDetail - 2)
        let card = localCard("create_note", ["body": body])
        XCTAssertEqual(card.detail.count, ApprovalCopy.maxWrappedDetail)
        XCTAssertEqual(card.detailLines, 3, "a note wraps rather than being cut")
        let layout = NotchSurfaceLayout()
        let tall = NotchApprovalBanner.thickness(for: card, banner: layout.bannerThickness)
        let geometry = NotchGeometry(notchWidth: 200, notchHeight: 37.5, screenWidth: 1512)
        XCTAssertLessThanOrEqual(tall, layout.panelSize(for: geometry).height - geometry.notchHeight)
    }
}
