import XCTest

@testable import WhisperMaster

/// The hand-off to Claude Code: the Desk session (`AgentDesk`,
/// `AgentSurfaceController.handToDesk`) and the two tools (`DelegateToolRunner`).
/// The rules pinned here are the ones that keep a task out of a coding session, keep
/// the card in front of every hand-off, and keep a replayed reply silent.
@MainActor
final class AgentDeskTests: XCTestCase {
    private let folder = "/Users/sam/code/proj"

    private func desk(_ id: String = "d1", state: KunaiWire.SessionState = .idle) -> AgentSession {
        var session = AgentSession(id: id, repo: "proj", title: AgentDesk.title, state: state)
        session.cwd = folder
        return session
    }

    private func coding(_ id: String = "c1", startedAt: Int64? = nil,
                        state: KunaiWire.SessionState = .idle) -> AgentSession {
        var session = AgentSession(id: id, repo: "proj", title: "fix the build", state: state,
                                   turnStartedAt: startedAt)
        session.cwd = folder
        return session
    }

    private func decode(_ json: String) throws -> KunaiWire.Event {
        try JSONDecoder().decode(KunaiWire.Event.self, from: Data(json.utf8))
    }

    /// A controller attached to `session`, past its hello (seq 50 is the boundary).
    private func attached(to session: AgentSession) throws -> AgentSurfaceController {
        let controller = AgentSurfaceController(candidates: [])
        controller.seedForSnapshot(
            ask: .approval(AgentApproval(requestID: "seed", tool: "Bash", headline: "x", detail: "r")),
            sessions: [session])
        controller.resolve(controller.ask!, allow: false)
        try controller.apply(decode(
            #"{"seq":51,"t":"hello","id":"\#(session.id)","epoch":"e1","high_seq":50,"mode":"default"}"#))
        return controller
    }

    // MARK: - Which session is the Desk

    func testAnOpenCodingSessionInTheSameFolderIsNeverTheDesk() {
        let open = coding(startedAt: 9_000)
        XCTAssertNil(AgentDesk.find(in: [open], folder: folder, rememberedID: nil),
                     "a coding session is not adopted as the Desk")
        XCTAssertEqual(AgentDesk.find(in: [open, desk()], folder: folder, rememberedID: nil)?.id, "d1")
    }

    func testADeskOnAnotherMachineIsNotThisMacsDesk() {
        var remote = desk()
        remote.machineLabel = "studio"
        XCTAssertNil(AgentDesk.find(in: [remote], folder: folder, rememberedID: "d1"))
    }

    func testTheAgentKeyFallbackNeverPicksTheDesk() {
        let controller = AgentSurfaceController(candidates: [])
        var recentDesk = desk()
        recentDesk.turnStartedAt = 9_000
        controller.seedGlanceForSnapshot(sessions: [coding(startedAt: 1_000), recentDesk])
        XCTAssertEqual(controller.promptTarget?.id, "c1", "the Desk ran last, but the key means a coding session")
    }

    func testAHandOffNeverLandsInTheOpenCodingSession() async {
        let controller = AgentSurfaceController(candidates: [])
        controller.seedGlanceForSnapshot(sessions: [coding(), desk()], openSessionID: "c1")

        // No socket can come up under test, so the hand-off fails at the Desk check.
        let failure = await controller.handToDesk("fix the failing test", folder: folder)

        XCTAssertNotNil(failure)
        XCTAssertEqual(controller.openSessionID, "c1", "the open session is given back untouched")
        XCTAssertNil(controller.log.lastUserPrompt, "nothing was sent to any session")
        XCTAssertFalse(controller.deskTurnPending)
    }

    // MARK: - No Desk without a folder

    func testThereIsNoDeskWithoutAProjectFolder() async {
        XCTAssertNil(AgentDesk.folder(""))
        XCTAssertNil(AgentDesk.folder("   "))
        XCTAssertNil(AgentDesk.folder("~", home: "/Users/sam"), "never the home folder")
        XCTAssertNil(AgentDesk.folder("/Users/sam/", home: "/Users/sam"))
        XCTAssertEqual(AgentDesk.folder("~/code/proj", home: "/Users/sam"), "/Users/sam/code/proj")
        XCTAssertNil(AgentDesk.folder("code/proj"), "a relative path has no fixed place")

        let controller = AgentSurfaceController(candidates: [])
        controller.seedGlanceForSnapshot(sessions: [coding()])
        let desk = await controller.ensureDesk(in: "")
        XCTAssertNil(desk)
        XCTAssertFalse(DelegateToolCatalog.offered(kunai: true, shed: false, deskFolder: nil,
                                                   consented: true, staysLocal: false)
            .contains(DelegateToolCatalog.delegateTask))
    }

    // MARK: - When the tools are offered

    func testNothingIsOfferedWithNoServer() {
        XCTAssertEqual(DelegateToolCatalog.offered(kunai: false, shed: false, deskFolder: folder,
                                                   consented: true, staysLocal: false), [])
        XCTAssertEqual(DelegateToolCatalog.offered(kunai: false, shed: true, deskFolder: folder,
                                                   consented: true, staysLocal: false).map(\.name),
                       ["list_coding_tasks"], "Shed has no route that starts a Desk")
        XCTAssertEqual(DelegateToolCatalog.offered(kunai: true, shed: false, deskFolder: folder,
                                                   consented: true, staysLocal: false).map(\.name),
                       ["delegate_task", "list_coding_tasks"])
    }

    func testAHandOffNeedsTheConsentAndACaptureThatMayLeaveTheMac() {
        let noConsent = DelegateToolCatalog.offered(kunai: true, shed: false, deskFolder: folder,
                                                    consented: false, staysLocal: false)
        let keptLocal = DelegateToolCatalog.offered(kunai: true, shed: false, deskFolder: folder,
                                                    consented: true, staysLocal: true)
        XCTAssertFalse(noConsent.contains(DelegateToolCatalog.delegateTask))
        XCTAssertFalse(keptLocal.contains(DelegateToolCatalog.delegateTask),
                       "a password manager in front or secure input keeps the capture here")
    }

    // MARK: - The card

    private final class Recorder {
        var cards: [PendingApproval] = []
        var handedOff: [String] = []
    }

    private func runner(_ recorder: Recorder, answer: ApprovalOutcome = .allowedOnce,
                        taint: Taint? = nil, handOffFailure: String? = nil,
                        sessions: [AgentSession] = []) -> DelegateToolRunner {
        DelegateToolRunner(
            environment: DelegateToolRunner.Environment(
                tools: [DelegateToolCatalog.delegateTask, DelegateToolCatalog.listCodingTasks],
                deskFolder: folder,
                handOff: { task, _ in recorder.handedOff.append(task); return handOffFailure },
                sessions: { sessions }),
            requestApproval: { recorder.cards.append($0); return answer },
            taint: taint ?? Taint())
    }

    private func delegate(_ task: String) -> ToolCall {
        ToolCall(tool: "delegate_task", arguments: ["task": task])
    }

    func testTheCardNamesTheDestinationShowsTheWholeTaskAndHasNoAlways() async throws {
        let recorder = Recorder()
        let task = "Find why the audio bench skips on CI and fix it, then run the whole test suite"
        let (result, handOff) = await runner(recorder).run(delegate(task))

        let card = try XCTUnwrap(recorder.cards.first)
        XCTAssertFalse(card.offersAlways)
        XCTAssertFalse(card.grantable)
        XCTAssertEqual(card.headline, "Send to Claude Code on this Mac, in proj")
        XCTAssertEqual(card.detail, "\u{201C}\(task)\u{201D}")
        XCTAssertEqual(card.detailLines, 2)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.endsTurn)
        XCTAssertEqual(recorder.handedOff, [task])
        XCTAssertEqual(handOff, HandOffTrace(destination: "Claude Code on this Mac, in proj",
                                             characters: task.count))
    }

    func testATaintedRunStillShowsTheCard() async throws {
        let recorder = Recorder()
        let taint = Taint()
        taint.isSet = true
        _ = await runner(recorder, taint: taint).run(delegate("summarise the open pull requests"))

        let card = try XCTUnwrap(recorder.cards.first, "after reading, the card is still the gate")
        XCTAssertNotNil(card.readWarning)
        XCTAssertFalse(card.offersAlways)
    }

    func testADeclinedCardHandsNothingOff() async {
        let recorder = Recorder()
        let (result, handOff) = await runner(recorder, answer: .denied).run(delegate("fix the build"))
        XCTAssertFalse(result.ok)
        XCTAssertFalse(result.endsTurn)
        XCTAssertNil(handOff)
        XCTAssertEqual(recorder.handedOff, [])
    }

    func testALongTaskScrollsOnTheCardWholeAndIsSentAsShown() async throws {
        let recorder = Recorder()
        let long = (0..<60).map { "word\($0)" }.joined(separator: " ")
        _ = await runner(recorder).run(delegate(long))

        let card = try XCTUnwrap(recorder.cards.first)
        XCTAssertTrue(card.scrollsDetail, "a long task is shown whole, never cut or refused")
        XCTAssertTrue(card.detail.contains(long))
        XCTAssertEqual(recorder.handedOff, [long])
    }

    func testATaskWithCharactersTheCardCannotShowIsRefusedBeforeTheCard() async {
        let recorder = Recorder()
        let (result, _) = await runner(recorder).run(delegate("fix the build\u{202E}txt.exe"))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(recorder.cards.count, 0)
        XCTAssertEqual(recorder.handedOff, [])
    }

    // MARK: - The turn ends after the hand-off

    private func notesStore() -> NotesStore {
        NotesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-\(UUID()).json"), load: false)
    }

    private func service(notes: NotesStore, approvals: ApprovalCoordinator,
                         recorder: Recorder, handOffFailure: String? = nil) -> CommandAgentService {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        return CommandAgentService(
            store: store, notes: notes, approvals: approvals, connectorsAllowed: false,
            now: { Date(timeIntervalSince1970: 1_760_000_000) },
            coding: DelegateToolRunner.Environment(
                tools: [DelegateToolCatalog.delegateTask],
                deskFolder: folder,
                handOff: { task, _ in recorder.handedOff.append(task); return handOffFailure }))
    }

    /// Answers the next card Once, the way a tap on the notch would.
    private func answerCards(_ approvals: ApprovalCoordinator, _ recorder: Recorder) {
        Task { @MainActor in
            for _ in 0..<2000 {
                if let pending = approvals.pending {
                    recorder.cards.append(pending)
                    approvals.resolve(.allowedOnce)
                    return
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    func testTheTurnEndsAtOnceAfterTheHandOff() async {
        let notes = notesStore()
        let approvals = ApprovalCoordinator()
        let recorder = Recorder()
        let model = ScriptedModel([
            #"{"tool":"delegate_task","args":{"task":"fix the failing test"}}"#,
            #"{"tool":"create_note","args":{"body":"this must never run"}}"#,
            #"{"answer":"Done."}"#,
        ])
        answerCards(approvals, recorder)

        let run = await service(notes: notes, approvals: approvals, recorder: recorder)
            .run("hand the failing test to claude", generate: model.generate)

        XCTAssertEqual(model.calls, 1, "the loop does not wait for the coding agent")
        XCTAssertEqual(notes.visibleNotes.count, 0)
        XCTAssertEqual(recorder.handedOff, ["fix the failing test"])
        XCTAssertEqual(run.result?.createdSomething, true, "a hand-off is an action")
        XCTAssertEqual(run.result?.detail, "Sent to Claude Code on this Mac, in proj")
        XCTAssertEqual(run.handOff?.characters, "fix the failing test".count)
        XCTAssertEqual(run.calls.map(\.tool), ["delegate_task"])
    }

    func testAFailedHandOffLetsTheLoopGoOn() async {
        let notes = notesStore()
        let approvals = ApprovalCoordinator()
        let recorder = Recorder()
        let model = ScriptedModel([
            #"{"tool":"delegate_task","args":{"task":"fix the failing test"}}"#,
            #"{"tool":"create_note","args":{"body":"Fix the failing test"}}"#,
            #"{"answer":"Saved it as a note."}"#,
        ])
        answerCards(approvals, recorder)

        let run = await service(notes: notes, approvals: approvals, recorder: recorder,
                                handOffFailure: "Couldn't reach Claude Code on this Mac.")
            .run("hand the failing test to claude", generate: model.generate)

        XCTAssertNil(run.handOff)
        XCTAssertEqual(notes.visibleNotes.count, 1, "the words still land")
        XCTAssertEqual(run.calls.first?.ok, false)
    }

    // MARK: - list_coding_tasks

    func testListingCodingTasksTaintsTheRunAndCapsTheRows() async {
        let recorder = Recorder()
        let taint = Taint()
        let sessions = (0..<12).map { coding("c\($0)") }
        let (result, _) = await runner(recorder, taint: taint, sessions: sessions)
            .run(ToolCall(tool: "list_coding_tasks", arguments: [:]))

        XCTAssertTrue(result.ok)
        XCTAssertTrue(taint.isSet, "session titles and status come from another program")
        XCTAssertTrue(taint.outsideSelection)
        let lines = result.text.split(separator: "\n")
        XCTAssertEqual(lines.count, DelegateToolCatalog.maxRows + 1)
        XCTAssertEqual(lines.last, "2 more not shown.")
        XCTAssertEqual(lines.first, "proj — this Mac — Idle — fix the build")
    }

    // MARK: - The Desk's own card and reply

    func testADeskAskOffersNoAlwaysAndDeniesItselfInTime() async throws {
        let controller = try attached(to: desk(state: .running))
        controller.deskAskTimeout = .milliseconds(20)
        try controller.apply(decode(
            #"{"seq":52,"t":"permission","request_id":"r1","tool_name":"Bash","input":{"command":"ls"}}"#))
        XCTAssertTrue(controller.askIsFromDesk)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(controller.ask, "an unanswered Desk ask is denied, never left waiting")
    }

    func testACodingSessionAskKeepsItsAlways() throws {
        let controller = try attached(to: coding(state: .running))
        try controller.apply(decode(
            #"{"seq":52,"t":"permission","request_id":"r1","tool_name":"Bash","input":{"command":"ls"}}"#))
        XCTAssertNotNil(controller.ask)
        XCTAssertFalse(controller.askIsFromDesk)
    }

    func testAReplayedDeskReplyIsNotSpoken() throws {
        let controller = try attached(to: desk(state: .running))
        var spoken: [String] = []
        controller.onDeskReply = { spoken.append($0) }
        controller.deskTurnPending = true

        try controller.apply(decode(
            #"{"seq":40,"t":"assistant","blocks":[{"type":"text","text":"Old reply."}]}"#))
        try controller.apply(decode(#"{"seq":41,"t":"result","duration_ms":5000}"#))
        XCTAssertEqual(spoken, [], "a reply kunai replays at attach is history")

        try controller.apply(decode(
            #"{"seq":52,"t":"assistant","blocks":[{"type":"text","text":"Fixed the test."}]}"#))
        try controller.apply(decode(#"{"seq":53,"t":"result","duration_ms":5000}"#))
        XCTAssertEqual(spoken, ["Fixed the test."])
        XCTAssertFalse(controller.deskTurnPending)
    }

    func testACodingSessionsReplyIsNeverSpoken() throws {
        let controller = try attached(to: coding(state: .running))
        var spoken: [String] = []
        controller.onDeskReply = { spoken.append($0) }
        controller.deskTurnPending = true

        try controller.apply(decode(
            #"{"seq":52,"t":"assistant","blocks":[{"type":"text","text":"Done."}]}"#))
        try controller.apply(decode(#"{"seq":53,"t":"result","duration_ms":5000}"#))
        XCTAssertEqual(spoken, [])
    }
}
