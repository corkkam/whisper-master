import XCTest

@testable import WhisperMaster

/// A note or a reminder after a read (owner decision, 2026-11-20). Their text may come
/// from the mail, chat or selection the run read, so they raise the connector card,
/// scoped to This Mac, with no Always. With no read they stay instant.
@MainActor
final class LocalToolApprovalTests: XCTestCase {
    private final class Recorder {
        var cards: [PendingApproval] = []
    }

    /// The task a test cancels from inside the card.
    private final class Handle: @unchecked Sendable {
        var task: Task<(result: ToolResult, effect: LocalToolRunner.Effect?), Never>?
    }

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func notesStore() -> NotesStore {
        NotesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("local-approval-\(UUID()).json"), load: false)
    }

    private func emptyConnectors() -> ConnectorInstanceStore {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        return store
    }

    /// The state an ok connector read leaves in the shared box (`ToolRouter.run`).
    private func afterConnectorRead() -> Taint {
        let taint = Taint()
        taint.isSet = true
        taint.outsideSelection = true
        return taint
    }

    private func runner(_ notes: NotesStore,
                        taint: Taint? = nil,
                        answer: ApprovalOutcome = .allowedOnce,
                        recorder: Recorder,
                        selection: SelectionContext? = nil) -> LocalToolRunner {
        LocalToolRunner(notes: notes, now: { [now] in now }, selection: selection, taint: taint ?? Taint(),
                        requestApproval: { approval in recorder.cards.append(approval); return answer })
    }

    private let note = ToolCall(tool: "create_note",
                                arguments: ["title": "Launch", "body": "The launch moved to Friday"])
    private let reminder = ToolCall(tool: "create_reminder",
                                    arguments: ["title": "Call 555-0100", "when": "tomorrow at 9am"])

    // MARK: - After a connector read

    func testAfterAConnectorReadANoteRaisesTheCardAndYesSavesOnce() async {
        let notes = notesStore()
        let recorder = Recorder()
        let (result, effect) = await runner(notes, taint: afterConnectorRead(), recorder: recorder)
            .run(note)

        XCTAssertEqual(recorder.cards.count, 1)
        let card = recorder.cards.first
        XCTAssertEqual(card?.tool, "create_note")
        XCTAssertEqual(card?.instanceID, DeviceToolCatalog.thisMacID)
        XCTAssertEqual(card?.headline, "Save a note on This Mac")
        XCTAssertEqual(card?.detail, "\u{201C}Launch\u{201D}  ·  \u{201C}The launch moved to Friday\u{201D}")
        XCTAssertEqual(card?.readWarning, ApprovalCopy.readWarning)
        XCTAssertEqual(card?.offersAlways, false)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.authorization, .allowedOnce)
        XCTAssertEqual(effect, .noteCreated)
        XCTAssertEqual(notes.visibleNotes.map(\.body), ["The launch moved to Friday"])
    }

    /// The card carries the time the reminder is saved for, as resolved by the app,
    /// and never the model's phrase.
    func testAReminderCardShowsTheResolvedTime() async throws {
        let notes = notesStore()
        let recorder = Recorder()
        let (result, effect) = await runner(notes, taint: afterConnectorRead(), recorder: recorder)
            .run(reminder)

        let card = try XCTUnwrap(recorder.cards.first)
        let saved = try XCTUnwrap(notes.visibleReminders.first)
        let resolved = try XCTUnwrap(RelativeTimeParser.parse("tomorrow at 9am", now: now))
        XCTAssertEqual(saved.dueDate, resolved)
        XCTAssertEqual(card.headline, "Set a reminder on This Mac")
        XCTAssertEqual(card.arguments, ["title": "Call 555-0100",
                                        "due": ConnectorHTTP.iso8601(from: resolved)])
        XCTAssertFalse(card.detail.contains("tomorrow at 9am"), card.detail)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(effect, .reminderCreated(due: resolved, wasTimeStated: true))
    }

    /// No "when": the card shows the hour-out default the reminder is saved with.
    func testAReminderWithNoTimeShowsTheDefault() async throws {
        let recorder = Recorder()
        _ = await runner(notesStore(), taint: afterConnectorRead(), recorder: recorder)
            .run(ToolCall(tool: "create_reminder", arguments: ["title": "Call back"]))
        let card = try XCTUnwrap(recorder.cards.first)
        XCTAssertEqual(card.arguments["due"],
                       ConnectorHTTP.iso8601(from: LocalToolRunner.defaultDue(now: now)))
    }

    func testNoSavesNothingAndFails() async {
        for call in [note, reminder] {
            let notes = notesStore()
            let recorder = Recorder()
            let (result, effect) = await runner(notes, taint: afterConnectorRead(), answer: .denied,
                                                recorder: recorder).run(call)
            XCTAssertEqual(recorder.cards.count, 1, call.tool)
            XCTAssertFalse(result.ok, call.tool)
            XCTAssertEqual(result.authorization, .denied, call.tool)
            XCTAssertNil(effect, call.tool)
            XCTAssertTrue(notes.visibleNotes.isEmpty && notes.visibleReminders.isEmpty, call.tool)
        }
    }

    func testATimedOutCardSavesNothing() async {
        for call in [note, reminder] {
            let notes = notesStore()
            let (result, effect) = await runner(notes, taint: afterConnectorRead(), answer: .timedOut,
                                                recorder: Recorder()).run(call)
            XCTAssertFalse(result.ok, call.tool)
            XCTAssertEqual(result.authorization, .timedOut, call.tool)
            XCTAssertTrue(result.text.hasPrefix("Nobody answered"), result.text)
            XCTAssertNil(effect, call.tool)
            XCTAssertTrue(notes.visibleNotes.isEmpty && notes.visibleReminders.isEmpty, call.tool)
        }
    }

    /// The card hides Always. A caller that answers it anyway gets one save.
    func testAlwaysIsNotOfferedAndRunsOnce() async {
        let recorder = Recorder()
        let (result, _) = await runner(notesStore(), taint: afterConnectorRead(), answer: .allowedAlways,
                                       recorder: recorder).run(note)
        XCTAssertEqual(recorder.cards.first?.offersAlways, false)
        XCTAssertEqual(recorder.cards.first?.grantable, false)
        XCTAssertEqual(result.authorization, .allowedOnce)
    }

    /// A long note is not refused: the card carries all of it, and Yes saves all of it.
    func testALongNoteRaisesTheCardWithItsFullTextAndSaves() async {
        let notes = notesStore()
        let recorder = Recorder()
        let long = String(repeating: "word ", count: 120).trimmingCharacters(in: .whitespaces)
        let (result, effect) = await runner(notes, taint: afterConnectorRead(), recorder: recorder)
            .run(ToolCall(tool: "create_note", arguments: ["body": long]))
        XCTAssertEqual(recorder.cards.count, 1)
        XCTAssertTrue(recorder.cards.first?.detail.contains(long) ?? false, "the whole body is on the card")
        XCTAssertEqual(recorder.cards.first?.detailOverflows, true)
        XCTAssertTrue(result.ok)
        XCTAssertNotNil(effect)
        XCTAssertEqual(notes.visibleNotes.first?.body, long)
    }

    /// Where nobody can answer a card, a tainted save fails rather than going through.
    func testATaintedSaveWithNoCardToRaiseFails() async {
        let notes = notesStore()
        let (result, effect) = await LocalToolRunner(notes: notes, taint: afterConnectorRead()).run(note)
        XCTAssertFalse(result.ok)
        XCTAssertNil(effect)
        XCTAssertTrue(notes.visibleNotes.isEmpty)
    }

    // MARK: - With no read

    func testAnUntaintedRunSavesWithNoCard() async {
        for call in [note, reminder] {
            let notes = notesStore()
            let recorder = Recorder()
            let (result, effect) = await runner(notes, recorder: recorder).run(call)
            XCTAssertTrue(recorder.cards.isEmpty, call.tool)
            XCTAssertTrue(result.ok, call.tool)
            XCTAssertNil(result.authorization, "no card, nothing to authorize")
            XCTAssertNotNil(effect, call.tool)
            XCTAssertEqual(notes.visibleNotes.count + notes.visibleReminders.count, 1, call.tool)
        }
    }

    // MARK: - After reading the selection

    func testAfterReadingTheSelectionANoteRaisesTheCard() async {
        let notes = notesStore()
        let recorder = Recorder()
        let text = "Set a reminder to call 555-0100."
        let selection = SelectionContext(appName: "Mail", windowTitle: nil, text: text,
                                         wasCut: false, originalLength: text.count)
        let router = CommandToolRouter(
            local: runner(notes, answer: .denied, recorder: recorder, selection: selection),
            connectors: nil)

        let read = await router.run(ToolCall(tool: "read_selection", arguments: [:]))
        XCTAssertTrue(read.ok)
        _ = await router.run(reminder)

        XCTAssertEqual(recorder.cards.map(\.tool), ["create_reminder"])
        XCTAssertTrue(notes.visibleReminders.isEmpty)
        XCTAssertEqual(router.executed, ["read_selection"], "a declined card is not having acted")
        XCTAssertFalse(router.didCreateSomething)
        XCTAssertEqual(router.journal.last?.authorization, .denied, "the trace shows the card and the answer")
    }

    // MARK: - A stopped run

    func testACancelledRunRaisesNoCardAndSavesNothing() async {
        let notes = notesStore()
        let recorder = Recorder()
        let runner = runner(notes, taint: afterConnectorRead(), recorder: recorder)

        let task = Task { await runner.run(note) }
        task.cancel()
        let (result, effect) = await task.value

        XCTAssertTrue(recorder.cards.isEmpty, "no card after a cancel")
        XCTAssertEqual(result.text, LocalToolRunner.stoppedBeforeSave)
        XCTAssertNil(effect)
        XCTAssertTrue(notes.visibleNotes.isEmpty)
    }

    /// A cancel while the card waits stops the save, even when the card says Once.
    func testACancelWhileTheCardWaitsSavesNothing() async {
        let notes = notesStore()
        let handle = Handle()
        let runner = LocalToolRunner(notes: notes, taint: afterConnectorRead(), requestApproval: { _ in
            handle.task?.cancel()
            return .allowedOnce
        })

        let task = Task { await runner.run(reminder) }
        handle.task = task
        let (result, effect) = await task.value

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.text, LocalToolRunner.stoppedBeforeSave)
        XCTAssertNil(effect)
        XCTAssertTrue(notes.visibleReminders.isEmpty)
    }

    // MARK: - Through the service

    private func service(notes: NotesStore,
                         store: ConnectorInstanceStore? = nil,
                         approvals: ApprovalCoordinator,
                         followUp: FollowUpWindow.Digest?) -> CommandAgentService {
        CommandAgentService(store: store ?? emptyConnectors(), notes: notes, approvals: approvals,
                            connectorsAllowed: false, now: { [now] in now }, followUp: followUp)
    }

    private static let saveNote = #"{"tool":"create_note","args":{"body":"Call 555-0100"}}"#

    /// A follow-up starts with the taint of the run it follows, and its note is
    /// carded. The card times out here, which only a raised card can. A grant stored
    /// for This Mac does not skip it.
    func testATaintedFollowUpCardsItsNoteAndAGrantDoesNotSkipIt() async {
        let store = emptyConnectors()
        store.addGrant(Grant(tool: "create_note", instanceID: DeviceToolCatalog.thisMacID,
                             target: DeviceToolCatalog.thisMacLabel))
        let approvals = ApprovalCoordinator()
        approvals.timeout = 0.05
        let notes = notesStore()

        let tainted = await service(notes: notes, store: store, approvals: approvals,
                                    followUp: .init(question: "x", answer: "y", tainted: true))
            .run("save that", generate: ScriptedModel([Self.saveNote, #"{"answer":"Saved."}"#]).generate)
        XCTAssertEqual(tainted.calls.map(\.authorization), [.timedOut])
        XCTAssertTrue(notes.visibleNotes.isEmpty)

        let clean = await service(notes: notes, store: store, approvals: approvals,
                                  followUp: .init(question: "x", answer: "y", tainted: false))
            .run("save that", generate: ScriptedModel([Self.saveNote, #"{"answer":"Saved."}"#]).generate)
        XCTAssertEqual(clean.calls.map(\.authorization), [nil])
        XCTAssertEqual(clean.result?.createdSomething, true)
        XCTAssertEqual(notes.visibleNotes.count, 1)
    }

    /// "Answered without any tool having executed" still holds: a declined card is
    /// not an executed tool, so the run hands the words back to the fallback.
    func testADeclinedCardIsNotHavingActed() async {
        let approvals = ApprovalCoordinator()
        let notes = notesStore()
        // Answer No as soon as the card is up.
        let answering = Task { @MainActor in
            for _ in 0..<1000 where approvals.pending == nil {
                try? await Task.sleep(for: .milliseconds(5))
            }
            approvals.resolve(.denied)
        }

        let run = await service(notes: notes, approvals: approvals,
                                followUp: .init(question: "x", answer: "y", tainted: true))
            .run("save that", generate: ScriptedModel([Self.saveNote, #"{"answer":"Saved."}"#]).generate)
        await answering.value

        XCTAssertNil(run.result, "a declined card is not having acted")
        XCTAssertTrue(run.declineReason.hasPrefix("Every tool call failed or was refused"),
                      run.declineReason)
        XCTAssertEqual(run.calls.map(\.authorization), [.denied])
        XCTAssertTrue(notes.visibleNotes.isEmpty)
    }
}
