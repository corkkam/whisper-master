import XCTest

@testable import WhisperMaster

/// `find_free_slots`, `update_calendar_event` and `delete_calendar_event`: the slot
/// rules, the title resolution, and the card an edit raises.
@MainActor
final class CalendarToolsTests: XCTestCase {
    private let calendar = Calendar.current

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 24) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func event(_ title: String, _ start: Date, _ end: Date,
                       allDay: Bool = false, recurring: Bool = false) -> DayEvent {
        var event = DayEvent(id: UUID().uuidString, title: title, start: start, end: end,
                             isAllDay: allDay, calendarTitle: "Home", sourceTitle: "iCloud",
                             instanceLabel: "Personal")
        event.isRecurring = recurring
        return event
    }

    private func busy(_ start: Date, _ end: Date, allDay: Bool = false) -> DayEvent {
        event("Busy", start, end, allDay: allDay)
    }

    private var workday: DateInterval { DateInterval(start: at(9), end: at(18)) }

    private func free(_ events: [DayEvent], minutes: Int = 30, notBefore: Date? = nil) -> [DateInterval] {
        FreeSlotFinder.slots(in: workday, events: events, minutes: minutes, notBefore: notBefore)
    }

    // MARK: - FreeSlotFinder

    func testNoEventsIsOneSlotForTheWholeWindow() {
        XCTAssertEqual(free([]), [workday])
    }

    func testOverlappingEventsBlockTheirUnion() {
        let slots = free([busy(at(10), at(11, 30)), busy(at(11), at(12))])
        XCTAssertEqual(slots, [DateInterval(start: at(9), end: at(10)),
                               DateInterval(start: at(12), end: at(18))])
    }

    func testBackToBackEventsLeaveNoGapBetweenThem() {
        let slots = free([busy(at(10), at(11)), busy(at(11), at(12))])
        XCTAssertEqual(slots, [DateInterval(start: at(9), end: at(10)),
                               DateInterval(start: at(12), end: at(18))])
    }

    func testAnAllDayEventIsNotBusy() {
        XCTAssertEqual(free([busy(at(0), at(0, day: 25), allDay: true)]), [workday])
    }

    func testAnEventAcrossTheWindowEdgeBlocksOnlyThePartInside() {
        let slots = free([busy(at(8), at(9, 30)), busy(at(17, 30), at(19))])
        XCTAssertEqual(slots, [DateInterval(start: at(9, 30), end: at(17, 30))])
    }

    func testAnEventAcrossMidnightBlocksOnlyThisDay() {
        let slots = free([busy(at(22, day: 23), at(10)), busy(at(17), at(1, day: 25))])
        XCTAssertEqual(slots, [DateInterval(start: at(10), end: at(17))])
    }

    func testADurationLongerThanAnyGapFindsNothing() {
        XCTAssertEqual(free([busy(at(9, 30), at(17, 30))], minutes: 60), [])
    }

    func testAtMostEightSlots() {
        // A half-hour gap before each of nine half-hour events.
        let events = (9...17).map { busy(at($0, 30), at($0 + 1)) }
        XCTAssertEqual(free(events).count, FreeSlotFinder.limit)
    }

    func testTodayStartsAtTheNextQuarterHourAfterNow() {
        XCTAssertEqual(free([], notBefore: at(10, 7)), [DateInterval(start: at(10, 15), end: at(18))])
        XCTAssertEqual(free([], notBefore: at(18, 30)), [])
    }

    func testTheWindowReadsSpokenHours() {
        let day = at(12)
        XCTAssertEqual(FreeSlotFinder.window(on: day, between: nil), workday)
        XCTAssertEqual(FreeSlotFinder.window(on: day, between: "9am to 6pm"), workday)
        XCTAssertEqual(FreeSlotFinder.window(on: day, between: "10 to 4"),
                       DateInterval(start: at(10), end: at(16)))
        XCTAssertEqual(FreeSlotFinder.window(on: day, between: "between 1pm and 3:30pm"),
                       DateInterval(start: at(13), end: at(15, 30)))
        XCTAssertNil(FreeSlotFinder.window(on: day, between: "the afternoon"))
        XCTAssertNil(FreeSlotFinder.window(on: day, between: "6pm to 9am"))
    }

    // MARK: - CalendarEventMatcher

    func testAnExactTitleWinsOverAPartialOne() {
        XCTAssertEqual(CalendarEventMatcher.matches("standup", titles: ["Standup prep", "Standup"]), [1])
    }

    func testAPartialMatchNeedsEverySpokenWord() {
        XCTAssertEqual(CalendarEventMatcher.matches("the standup meeting", titles: ["Daily Standup"]), [0])
        XCTAssertEqual(CalendarEventMatcher.matches("design standup", titles: ["Daily Standup"]), [])
    }

    func testTwoEventsWithTheNameAreBothReturned() {
        XCTAssertEqual(CalendarEventMatcher.matches("review", titles: ["Design review", "Code review"]), [0, 1])
        XCTAssertEqual(CalendarEventMatcher.matches("focus", titles: ["Focus", "Lunch", "Focus"]), [0, 2])
    }

    func testFillerAloneNamesNothing() {
        XCTAssertEqual(CalendarEventMatcher.matches("the meeting", titles: ["Standup"]), [])
    }

    // MARK: - The router

    private func personal() -> ConnectorInstanceStore {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        store.add(ConnectorInstance(
            kind: .appleCalendar, label: "Personal", identity: "iCloud",
            config: .calendars(identifiers: ["cal-1"], sourceTitle: "iCloud")))
        return store
    }

    private func router(_ store: ConnectorInstanceStore,
                        _ calendar: StubCalendar,
                        taint: Taint? = nil,
                        approval: @escaping (PendingApproval) async -> ApprovalOutcome) -> ToolRouter {
        let now = at(8)
        var router = ToolRouter(store: store, requestApproval: approval, now: { now }, taint: taint ?? Taint())
        router.writeProvider = { _ in calendar }
        return router
    }

    private func move(_ title: String, to when: String = "at 3pm") -> ToolCall {
        ToolCall(tool: "update_calendar_event", arguments: ["event": title, "when": when])
    }

    func testTheSchemaRefusesAnUpdateWithNeitherWhenNorTitle() async {
        let stub = StubCalendar(events: [event("Standup", at(9), at(9, 30))])
        var asked = false
        let result = await router(personal(), stub) { _ in asked = true; return .allowedOnce }
            .run(ToolCall(tool: "update_calendar_event", arguments: ["event": "Standup"]))

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.text.contains("\"when\""))
        XCTAssertFalse(asked)
        XCTAssertEqual(stub.reads, 0, "refused before the calendar is read")
    }

    func testNoMatchFailsClosedAndListsTheDay() async {
        let stub = StubCalendar(events: [event("Standup", at(9), at(9, 30)), event("Lunch", at(12), at(13))])
        var asked = false
        let result = await router(personal(), stub) { _ in asked = true; return .allowedOnce }
            .run(move("Design review"))

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.text.contains("Standup") && result.text.contains("Lunch"), result.text)
        XCTAssertFalse(asked)
        XCTAssertTrue(stub.edits.isEmpty)
    }

    func testTwoMatchesFailClosed() async {
        let stub = StubCalendar(events: [event("Focus", at(9), at(10)), event("Focus", at(14), at(15))])
        var asked = false
        let result = await router(personal(), stub) { _ in asked = true; return .allowedOnce }
            .run(ToolCall(tool: "delete_calendar_event", arguments: ["event": "focus"]))

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.text.contains("More than one"), result.text)
        XCTAssertFalse(asked)
        XCTAssertTrue(stub.edits.isEmpty)
    }

    func testOneMatchShowsTheEventOnACardWithNoAlways() async {
        let stub = StubCalendar(events: [event("Standup", at(9), at(9, 30))])
        let store = personal()
        var card: PendingApproval?
        let result = await router(store, stub) { approval in card = approval; return .allowedAlways }
            .run(move("standup"))

        XCTAssertEqual(card?.offersAlways, false)
        XCTAssertNil(card?.readWarning, "nothing was read before this card")
        XCTAssertEqual(card?.headline, "Change \u{201C}Standup\u{201D} on Personal")
        XCTAssertTrue(card?.detail.contains("\u{2192}") ?? false, card?.detail ?? "")
        XCTAssertFalse(card?.detail.contains("event_id") ?? true, "the card never shows a provider id")
        // An Always that arrives anyway runs once and stores nothing.
        XCTAssertEqual(result.authorization, .allowedOnce)
        XCTAssertTrue(store.grants.isEmpty)
        // The move keeps the event's length.
        guard case .update(nil, let start?, let end?) = stub.edits.first?.change else {
            return XCTFail("expected one move")
        }
        XCTAssertEqual(start, at(15))
        XCTAssertEqual(end, at(15, 30))
    }

    func testAGrantNeverAnswersAnEdit() async {
        let store = personal()
        store.addGrant(Grant(tool: "delete_calendar_event", instanceID: store.ordered[0].id, target: "Standup"))
        let stub = StubCalendar(events: [event("Standup", at(9), at(9, 30))])
        var asked = false
        let result = await router(store, stub) { _ in asked = true; return .allowedOnce }
            .run(ToolCall(tool: "delete_calendar_event", arguments: ["event": "Standup"]))

        XCTAssertTrue(asked)
        XCTAssertEqual(result.authorization, .allowedOnce)
    }

    func testATaintedRunShowsTheCardWithTheWarning() async {
        let taint = Taint()
        taint.isSet = true
        let stub = StubCalendar(events: [event("Standup", at(9), at(9, 30))])
        var card: PendingApproval?
        _ = await router(personal(), stub, taint: taint) { approval in card = approval; return .denied }
            .run(ToolCall(tool: "delete_calendar_event", arguments: ["event": "Standup"]))

        XCTAssertNotNil(card?.readWarning)
        XCTAssertEqual(card?.offersAlways, false)
        XCTAssertTrue(stub.edits.isEmpty, "a denied card changes nothing")
    }

    func testAnEditTaintsTheRunForTheWritesAfterIt() async {
        let taint = Taint()
        let stub = StubCalendar(events: [event("Standup", at(9), at(9, 30))])
        _ = await router(personal(), stub, taint: taint) { _ in .denied }.run(move("Lunch"))

        XCTAssertTrue(taint.isSet, "the result listed other people's event titles")
    }

    func testARecurringOccurrenceSaysSoOnTheCard() async {
        let stub = StubCalendar(events: [event("Standup", at(9), at(9, 30), recurring: true)])
        var card: PendingApproval?
        _ = await router(personal(), stub) { approval in card = approval; return .denied }
            .run(ToolCall(tool: "delete_calendar_event", arguments: ["event": "Standup"]))

        XCTAssertTrue(card?.detail.contains("This occurrence only") ?? false, card?.detail ?? "")
    }

    func testAFailedProviderWriteIsNotExecuted() async {
        let stub = StubCalendar(events: [event("Standup", at(9), at(9, 30))], result: .failed("Read-only."))
        let notes = NotesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("calendar-edit-\(UUID()).json"), load: false)
        let commands = CommandToolRouter(
            local: LocalToolRunner(notes: notes),
            connectors: router(personal(), stub) { _ in .allowedOnce })

        let result = await commands.run(ToolCall(tool: "delete_calendar_event", arguments: ["event": "Standup"]))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(stub.edits.count, 1, "the write reached the provider")
        XCTAssertEqual(commands.executed, [])
        XCTAssertFalse(commands.didCreateSomething)
    }

    func testEditsArePublishedOnlyWhereAProviderCanEdit() {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        store.add(ConnectorInstance(kind: .zoom, label: "Meetings", identity: "acme"))
        let zoomOnly = Set(ToolRegistry.available(store: store).map(\.name))
        XCTAssertTrue(zoomOnly.contains("find_free_slots"))
        XCTAssertFalse(zoomOnly.contains("update_calendar_event"))
        XCTAssertFalse(zoomOnly.contains("delete_calendar_event"))

        store.add(ConnectorInstance(
            kind: .appleCalendar, label: "Personal", identity: "iCloud",
            config: .calendars(identifiers: ["cal-1"], sourceTitle: "iCloud")))
        let update = ToolRegistry.available(store: store).first { $0.name == "update_calendar_event" }
        XCTAssertEqual(update?.parameters.first?.allowedValues, ["Personal"])
    }

    // MARK: - Copy

    func testTheDeleteCardShowsTheTimeAndTheCalendar() {
        let arguments = CalendarEdit.arguments(for: event("Standup", at(9), at(9, 30)),
                                               title: nil, start: nil, end: nil)
        XCTAssertEqual(ApprovalCopy.headline(tool: "delete_calendar_event", target: "Standup",
                                             instanceLabel: "Personal"),
                       "Delete \u{201C}Standup\u{201D} on Personal")
        let detail = ApprovalCopy.detail(tool: "delete_calendar_event", arguments: arguments, now: at(8))
        XCTAssertTrue(detail.hasPrefix("Today "), detail)
        XCTAssertFalse(detail.contains("event_") || detail.contains("2026"), "no raw keys or ISO times: \(detail)")
    }
}

/// A calendar connection that reads fixed events and records each edit it receives.
@MainActor
private final class StubCalendar: CalendarEditingProvider {
    nonisolated static var kind: ConnectorKind { .appleCalendar }
    let events: [DayEvent]
    let result: WriteResult
    private(set) var reads = 0
    private(set) var edits: [CalendarEdit] = []

    init(events: [DayEvent], result: WriteResult = .done("Done.")) {
        self.events = events
        self.result = result
    }

    nonisolated func validate(_ credential: ConnectorCredential,
                              config: ConnectorConfig) async -> ValidationResult {
        .invalid("Not used.")
    }

    func eventsToEdit(on day: Date, instance: ConnectorInstance) async -> ProviderReadOutcome<[DayEvent]> {
        reads += 1
        return ProviderReadOutcome(events)
    }

    func performEdit(_ edit: CalendarEdit, instance: ConnectorInstance) async -> WriteResult {
        edits.append(edit)
        return result
    }

    func performWrite(tool: String, arguments: [String: String],
                      instance: ConnectorInstance) async -> WriteResult {
        .failed("Not an edit.")
    }
}
