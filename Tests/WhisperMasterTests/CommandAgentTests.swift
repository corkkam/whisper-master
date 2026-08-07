import XCTest

@testable import WhisperMaster

/// The fn + control chord run as an agent: the model picks a tool, the tool acts on
/// the user's own store, and the band gets a report of what happened.
///
/// The generator is scripted for the same reason `AgentLoopTests` scripts it — MLX
/// inference can't run under `swift test` at all — so what's pinned here is the
/// control flow around the model, which is the part that decides whether a spoken
/// command lands or evaporates.
@MainActor
final class CommandAgentTests: XCTestCase {
    private func notesStore() -> NotesStore {
        NotesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("cmd-agent-\(UUID()).json"), load: false)
    }

    private func emptyConnectors() -> ConnectorInstanceStore {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        return store
    }

    private func calendarConnectors() -> ConnectorInstanceStore {
        let store = emptyConnectors()
        store.add(ConnectorInstance(
            kind: .googleCalendar, label: "Work", identity: "sam@acme.com",
            config: .calendars(identifiers: ["cal-1"], sourceTitle: "Google")))
        return store
    }

    private func scripted(_ replies: [String]) -> AgentLoop.Generate {
        ScriptedModel(replies).generate
    }

    private func service(notes: NotesStore,
                         connectors: ConnectorInstanceStore,
                         connectorsAllowed: Bool = false,
                         now: Date = Date(timeIntervalSince1970: 1_760_000_000))
        -> CommandAgentService {
        CommandAgentService(
            store: connectors,
            notes: notes,
            approvals: ApprovalCoordinator(),
            connectorsAllowed: connectorsAllowed,
            now: { now })
    }

    // MARK: - Filing

    func testAReminderCommandCreatesAReminder() async {
        let notes = notesStore()
        let result = await service(notes: notes, connectors: emptyConnectors()).perform(
            "remind me to call mom tomorrow at 9",
            generate: scripted([
                #"{"tool":"create_reminder","args":{"title":"Call mom","when":"tomorrow at 9"}}"#,
                #"{"answer":"Reminder set for tomorrow at 9."}"#,
            ]))

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.createdSomething ?? false)
        XCTAssertEqual(notes.visibleReminders.count, 1)
        XCTAssertEqual(notes.visibleReminders.first?.title, "Call mom")
        XCTAssertEqual(result?.detail, "Saved to Notes & Reminders")
    }

    func testANoteCommandCreatesANote() async {
        let notes = notesStore()
        let result = await service(notes: notes, connectors: emptyConnectors()).perform(
            "the wifi password is hunter two",
            generate: scripted([
                #"{"tool":"create_note","args":{"body":"The wifi password is hunter two"}}"#,
                #"{"answer":"Saved that note."}"#,
            ]))

        XCTAssertEqual(result?.answer, "Saved that note.")
        XCTAssertEqual(notes.visibleNotes.count, 1)
        XCTAssertEqual(notes.visibleNotes.first?.body, "The wifi password is hunter two")
    }

    /// The time comes back as the *phrase* the user spoke and is parsed here. A model
    /// asked for a timestamp invents plausible, wrong ones.
    func testAnUnparseableTimeStillFilesTheReminder() async {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let notes = notesStore()
        let result = await service(notes: notes, connectors: emptyConnectors(), now: now).perform(
            "remind me to stretch",
            generate: scripted([
                #"{"tool":"create_reminder","args":{"title":"Stretch","when":"sometime soonish"}}"#,
                #"{"answer":"Reminder set."}"#,
            ]))

        XCTAssertTrue(result?.createdSomething ?? false)
        XCTAssertEqual(notes.visibleReminders.count, 1)
        XCTAssertEqual(notes.visibleReminders.first?.dueDate,
                       LocalToolRunner.defaultDue(now: now),
                       "an unreadable phrase falls back to the hour-out default, not a guess")
    }

    // MARK: - Refusing to guess

    /// The safety property the whole path hangs on: the paste is suppressed for an
    /// armed capture, so a model that *talks* instead of acting has thrown the user's
    /// words away. Reporting nil is what sends the caller to the deterministic
    /// keyword path, which always files something.
    func testAnAnswerWithNoToolCallIsNotAccepted() async {
        let notes = notesStore()
        let result = await service(notes: notes, connectors: emptyConnectors()).perform(
            "buy milk",
            generate: scripted([#"{"answer":"Sure, I'll remember that."}"#]))

        XCTAssertNil(result, "talking is not acting")
        XCTAssertTrue(notes.visibleNotes.isEmpty)
        XCTAssertTrue(notes.visibleReminders.isEmpty)
    }

    /// …but a loop that runs dry *after* creating something has still carried the
    /// command out. Handing nil back there would file the same words a second time
    /// through the deterministic path and caption it "Note saved" — two lies about one
    /// command — so the tool's own report stands in for the summary.
    func testALoopThatRunsDryAfterActingStillReportsWhatItDid() async {
        let notes = notesStore()
        let result = await service(notes: notes, connectors: emptyConnectors()).perform(
            "remind me to file taxes",
            generate: scripted([
                #"{"tool":"create_reminder","args":{"title":"File taxes"}}"#,
                "still not json", "nor this", "nor this either", "or this",
            ]))

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.createdSomething ?? false)
        XCTAssertTrue(result?.answer.hasPrefix("Reminder set for") ?? false, result?.answer ?? "nil")
        XCTAssertEqual(notes.visibleReminders.count, 1, "and exactly once")
    }

    func testAnExhaustedLoopIsNotAccepted() async {
        let notes = notesStore()
        let result = await service(notes: notes, connectors: emptyConnectors()).perform(
            "buy milk",
            generate: scripted(Array(repeating: "not json", count: 10)))
        XCTAssertNil(result)
    }

    /// A rejected call must not reach the store, and the loop gets to correct itself.
    func testAMalformedCallDoesNotFileAnything() async {
        let notes = notesStore()
        let result = await service(notes: notes, connectors: emptyConnectors()).perform(
            "note this",
            generate: scripted([
                #"{"tool":"create_note","args":{"content":"wrong key"}}"#,
                #"{"tool":"create_note","args":{"body":"the right one"}}"#,
                #"{"answer":"Saved."}"#,
            ]))

        XCTAssertEqual(notes.visibleNotes.count, 1)
        XCTAssertEqual(notes.visibleNotes.first?.body, "the right one")
        XCTAssertTrue(result?.createdSomething ?? false)
    }

    /// An empty body is the model producing a call-shaped nothing. It must be refused
    /// at the runner, not saved as a blank note.
    func testAnEmptyNoteBodyIsRefused() async {
        let notes = notesStore()
        _ = await service(notes: notes, connectors: emptyConnectors()).perform(
            "…",
            generate: scripted([
                #"{"tool":"create_note","args":{"body":"   "}}"#,
                #"{"answer":"Done."}"#,
            ]))
        XCTAssertTrue(notes.visibleNotes.isEmpty)
    }

    // MARK: - Tool surface

    /// Notes and reminders are always reachable from the chord; connectors only when
    /// the user has opted the assistant into them.
    func testConnectorToolsAreWithheldUntilTheAssistantIsOptedIn() async {
        let notes = notesStore()
        let connectors = calendarConnectors()

        let refused = await service(notes: notes, connectors: connectors,
                                    connectorsAllowed: false).perform(
            "what's on my calendar",
            generate: scripted([
                #"{"tool":"list_calendar_events","args":{}}"#,
                #"{"answer":"Nothing."}"#,
            ]))
        XCTAssertNil(refused, "the calendar tool isn't published, so the call is rejected")

        let names = (LocalToolCatalog.all
            + ToolRegistry.available(store: connectors)).map(\.name)
        XCTAssertTrue(names.contains("create_note"))
        XCTAssertTrue(names.contains("create_reminder"))
        XCTAssertTrue(names.contains("list_calendar_events"))
    }

    func testLocalToolsNeedNoConnectorAndCarryNoProvenance() async {
        let notes = notesStore()
        notes.upsertReminder(ReminderItem(title: "Standup",
                                          dueDate: Date(timeIntervalSince1970: 1_760_003_600)))
        let result = await service(notes: notes, connectors: emptyConnectors()).perform(
            "what have I got coming up",
            generate: scripted([
                #"{"tool":"list_reminders","args":{}}"#,
                #"{"answer":"One: standup."}"#,
            ]))

        XCTAssertEqual(result?.answer, "One: standup.")
        XCTAssertFalse(result?.createdSomething ?? true, "reading created nothing")
        XCTAssertEqual(result?.detail, "On-device assistant",
                       "the user's own notes are not a connector to credit")
    }

    // MARK: - What counts as having acted

    /// **A connector write is something happening.** The tally was derived from the
    /// local runner's effects alone, so a Slack message that genuinely went out left
    /// `didCreateSomething` false — and an exhausted loop then told the user nothing
    /// had happened about a message that had already been sent.
    ///
    /// The router is stubbed because no provider can complete a real write under
    /// `swift test`.
    func testAConnectorWriteCountsAsHavingActed() async {
        let connectors = StubConnectorRouter(
            ToolResult(ok: true, text: "Sent to #ops.", instanceLabels: ["Work chat"]))
        let router = CommandToolRouter(local: LocalToolRunner(notes: notesStore()),
                                       connectors: connectors)

        let result = await router.run(ToolCall(
            tool: "send_message", arguments: ["channel": "#ops", "text": "hi"]))

        XCTAssertTrue(result.ok)
        XCTAssertTrue(router.didCreateSomething, "the message went out")
        XCTAssertEqual(router.lastResult, "Sent to #ops.",
                       "so an exhausted loop has the tool's own report to fall back on")
        XCTAssertEqual(router.effects,
                       [.connectorWrite(tool: "send_message", instanceLabels: ["Work chat"])])
    }

    /// A write the user declined, or one the provider refused, reached the connector
    /// and changed nothing — the deterministic fallback must still get the words.
    func testAFailedConnectorWriteDoesNotCount() async {
        let connectors = StubConnectorRouter(.failure("The user declined that."))
        let router = CommandToolRouter(local: LocalToolRunner(notes: notesStore()),
                                       connectors: connectors)

        _ = await router.run(ToolCall(
            tool: "send_message", arguments: ["channel": "#ops", "text": "hi"]))

        XCTAssertFalse(router.didCreateSomething)
        XCTAssertTrue(router.effects.isEmpty)
    }

    /// Reading still doesn't count: the answer is the whole of its result.
    func testAConnectorReadDoesNotCount() async {
        let connectors = StubConnectorRouter(
            ToolResult(ok: true, text: "Nothing on the calendar today.",
                       instanceLabels: ["Work"]))
        let router = CommandToolRouter(local: LocalToolRunner(notes: notesStore()),
                                       connectors: connectors)

        _ = await router.run(ToolCall(tool: "list_calendar_events", arguments: [:]))

        XCTAssertFalse(router.didCreateSomething)
        XCTAssertTrue(router.effects.isEmpty)
    }

    /// A local tool has no consent card to bind a grant to, so it must never be
    /// dispatched through the connector router.
    func testTheConnectorRouterRefusesALocalTool() async {
        let router = ToolRouter(store: emptyConnectors(), requestApproval: { _ in .denied })
        let result = await router.run(ToolCall(tool: "create_note", arguments: ["body": "hi"]))
        XCTAssertFalse(result.ok)
    }

    // MARK: - What the band shows

    func testTheBandLineIsClampedAtAWordBoundary() {
        let long = "You have three meetings today and the first one starts in about twenty minutes"
        let line = DictationViewModel.bandLine(long)
        XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertLessThanOrEqual(line.count, 59)
        XCTAssertFalse(line.dropLast().hasSuffix(" "), "the ellipsis follows a whole word")
        XCTAssertEqual(DictationViewModel.bandLine("Reminder set."), "Reminder set.",
                       "a short line is left exactly as it is")
    }
}
