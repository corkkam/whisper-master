import XCTest

@testable import WhisperMaster

/// The follow-up window: the last answer, offered to the next chord capture for two
/// minutes, in memory only, never a run of the selection, and never across a sign-out.
@MainActor
final class FollowUpWindowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    private func notesStore() -> NotesStore {
        NotesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("follow-up-\(UUID()).json"), load: false)
    }

    private func emptyConnectors() -> ConnectorInstanceStore {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        return store
    }

    private func service(selection: SelectionContext? = nil,
                         followUp: FollowUpWindow.Digest? = nil,
                         connectors: ConnectorInstanceStore? = nil,
                         approvals: ApprovalCoordinator? = nil) -> CommandAgentService {
        CommandAgentService(
            store: connectors ?? emptyConnectors(),
            notes: notesStore(),
            approvals: approvals ?? ApprovalCoordinator(),
            connectorsAllowed: connectors != nil,
            now: { Date(timeIntervalSince1970: 1_760_000_000) },
            selection: selection,
            followUp: followUp)
    }

    /// A run that read the reminders and answered.
    private func answeredRun(_ answer: String) async -> CommandAgentService.Run {
        await service().run("what reminders do I have", generate: ScriptedModel([
            #"{"tool":"list_reminders","args":{}}"#,
            #"{"answer":"\#(answer)"}"#,
        ]).generate)
    }

    // MARK: - The window

    func testTheDigestIsOfferedForTwoMinutesAndNoLonger() async {
        let run = await answeredRun("Nothing is set.")
        let window = FollowUpWindow()

        window.remember(run, question: "what reminders do I have",
                        generation: window.generation, at: start)
        XCTAssertNotNil(window.take(at: start.addingTimeInterval(119)))

        window.remember(run, question: "what reminders do I have",
                        generation: window.generation, at: start)
        XCTAssertNil(window.take(at: start.addingTimeInterval(120)), "it expires by time alone")
    }

    func testTheDigestIsHandedOverOnce() async {
        let window = FollowUpWindow()
        let run = await answeredRun("Nothing is set.")
        window.remember(run, question: "q", generation: window.generation, at: start)

        XCTAssertNotNil(window.take(at: start))
        XCTAssertNil(window.take(at: start), "the next capture takes it; the one after gets nothing")
    }

    func testANewRunReplacesIt() async {
        let window = FollowUpWindow()
        let first = await answeredRun("First answer.")
        let second = await answeredRun("Second answer.")
        window.remember(first, question: "first", generation: window.generation, at: start)
        window.remember(second, question: "second", generation: window.generation, at: start)
        XCTAssertEqual(window.take(at: start)?.answer, "Second answer.")

        // A run that answered nothing leaves nothing to follow.
        window.remember(first, question: "first", generation: window.generation, at: start)
        let declined = await service().run("hmm", generate: ScriptedModel([]).generate)
        window.remember(declined, question: "hmm", generation: window.generation, at: start)
        XCTAssertNil(window.take(at: start))
    }

    func testAReceiptIsNotOffered() async {
        let filed = await service().run("remind me to call mom", generate: ScriptedModel([
            #"{"tool":"create_reminder","args":{"title":"Call mom"}}"#,
            #"{"answer":"Reminder set."}"#,
        ]).generate)
        XCTAssertEqual(filed.result?.createdSomething, true)

        let window = FollowUpWindow()
        window.remember(filed, question: "remind me to call mom",
                        generation: window.generation, at: start)
        XCTAssertNil(window.take(at: start))
    }

    func testClearForgetsIt() async {
        let window = FollowUpWindow()
        let run = await answeredRun("Nothing is set.")
        window.remember(run, question: "q", generation: window.generation, at: start)
        window.clear()
        XCTAssertNil(window.take(at: start))
    }

    /// A run in flight at sign-out finishes later; it read the generation when it
    /// started, so it cannot leave the old account's answer for the next one.
    func testARunThatBeganBeforeAClearCannotRemember() async {
        let window = FollowUpWindow()
        let startedAt = window.generation
        window.clear()
        let late = await answeredRun("Old account's mail.")
        window.remember(late, question: "q", generation: startedAt, at: start)
        XCTAssertNil(window.take(at: start))
    }

    /// The real sign-out path: the view model's handler the delegate calls.
    func testSignOutClearsTheWindowAndRefusesALateRun() async {
        let viewModel = DictationViewModel()
        let run = await answeredRun("Two meetings.")
        viewModel.followUps.remember(run, question: "q",
                                     generation: viewModel.followUps.generation, at: start)
        let inFlight = viewModel.followUps.generation

        viewModel.handleSignOut()
        XCTAssertNil(viewModel.followUps.take(at: start), "sign-out forgets the held answer")

        viewModel.followUps.remember(run, question: "q", generation: inFlight, at: start)
        XCTAssertNil(viewModel.followUps.take(at: start), "a run from before sign-out remembers nothing")
    }

    func testTheDigestIsOneLineEachAndAtMost400Characters() {
        let digest = FollowUpWindow.Digest(question: String(repeating: "why\n", count: 200),
                                           answer: String(repeating: "because\n", count: 200),
                                           tainted: false)
        XCTAssertLessThanOrEqual(digest.question.count + digest.answer.count, FollowUpWindow.limit)
        XCTAssertFalse((digest.question + digest.answer).contains("\n"))
        XCTAssertTrue(digest.answer.hasPrefix("because because"),
                      "a long question cannot push the answer out: \(digest.answer)")
        XCTAssertGreaterThan(digest.answer.count, FollowUpWindow.limit / 2)
    }

    // MARK: - The selection stays out

    func testAnAnswerThatRepeatsTheSelectionIsNeverInTheDigest() async {
        let sentinel = "SENTINEL-do-not-persist, the quarterly numbers are confidential"
        let picked = SelectionContext(appName: "Mail", windowTitle: nil, text: sentinel,
                                      wasCut: false, originalLength: sentinel.count)
        let run = await service(selection: picked).run("summarize this", generate: ScriptedModel([
            #"{"tool":"read_selection","args":{}}"#,
            #"{"answer":"It says: \#(sentinel)"}"#,
        ]).generate)
        XCTAssertEqual(run.result?.answer, "It says: \(sentinel)", "the band still shows it")

        let window = FollowUpWindow()
        window.remember(run, question: "summarize this", generation: window.generation, at: start)
        let digest = window.take(at: start)
        XCTAssertNotNil(digest)
        XCTAssertFalse(digest?.answer.contains("SENTINEL") ?? true)
        XCTAssertEqual(digest?.tainted, true, "a selection read taints the follow-up")
    }

    // MARK: - The next run

    /// The digest is an earlier turn of the conversation, never part of the rules.
    func testTheNextRunCarriesItAsAnEarlierTurnNotInTheSystemPrompt() async {
        let digest = FollowUpWindow.Digest(question: "what's on today",
                                           answer: "Two meetings, first at ten.", tainted: false)
        let with = PromptRecorder()
        _ = await service(followUp: digest).run("and tomorrow?", generate: with.generate)
        XCTAssertTrue(with.text.contains("Question: what's on today"))
        XCTAssertTrue(with.text.contains(#"You replied: {"answer":"Two meetings, first at ten."}"#))
        XCTAssertTrue(with.text.hasSuffix("Question: and tomorrow?"), "the new command comes last")
        XCTAssertFalse(with.prompt.contains("Two meetings"))
        XCTAssertFalse(with.prompt.contains("what's on today"))

        let without = PromptRecorder()
        _ = await service().run("and tomorrow?", generate: without.generate)
        XCTAssertEqual(without.text, "Question: and tomorrow?")
    }

    /// A follow-up to a tainted run starts tainted: the card answers for a write the
    /// user once allowed. It times out here, which only a raised card can.
    func testATaintedDigestTaintsTheNextRun() async {
        let store = emptyConnectors()
        let slack = store.add(ConnectorInstance(kind: .slack, label: "Work chat", identity: "team"))
        store.addGrant(Grant(tool: "send_message", instanceID: slack.id, target: "#ops"))
        let approvals = ApprovalCoordinator()
        approvals.timeout = 0.05
        let send = ##"{"tool":"send_message","args":{"channel":"#ops","text":"hi"}}"##

        let tainted = await service(
            followUp: .init(question: "x", answer: "y", tainted: true),
            connectors: store, approvals: approvals
        ).run("post that to ops", generate: ScriptedModel([send, #"{"answer":"Done."}"#]).generate)
        XCTAssertEqual(tainted.calls.last?.authorization, .timedOut)
        XCTAssertTrue(tainted.tainted)

        let clean = await service(
            followUp: .init(question: "x", answer: "y", tainted: false),
            connectors: store, approvals: approvals
        ).run("post hi to ops", generate: ScriptedModel([send, #"{"answer":"Done."}"#]).generate)
        XCTAssertEqual(clean.calls.last?.authorization, .standingGrant)
    }

    /// The digest lives in the conversation only: nothing the run stores carries it.
    func testTheDigestIsNotStoredInTheRunsTrace() async throws {
        let sentinel = "SENTINEL-previous-answer"
        let digest = FollowUpWindow.Digest(question: "q", answer: sentinel, tainted: false)
        let run = await service(followUp: digest).run("and tomorrow?", generate: ScriptedModel([
            #"{"tool":"list_reminders","args":{}}"#,
            #"{"answer":"Nothing tomorrow."}"#,
        ]).generate)

        let stored = String(decoding: try JSONEncoder().encode(run.calls), as: UTF8.self)
            + String(decoding: try JSONEncoder().encode(run.turns), as: UTF8.self)
            + run.storableAnswer + run.declineReason
        XCTAssertFalse(stored.contains(sentinel))
    }

    // MARK: - Escape

    func testEscapeWithNothingPendingDoesNothing() {
        let viewModel = DictationViewModel()
        viewModel.state.activeDaySummary = DaySummary(
            headline: "Two meetings.", detail: "", events: [], gaps: [], scopedTo: nil,
            question: "what's on today")
        viewModel.state.daySummaryAt = Date()

        XCTAssertFalse(viewModel.handleAssistantEscape())
        XCTAssertNotNil(viewModel.state.activeDaySummary, "a one-line answer is left alone")
    }

    func testEscapeDeniesAWaitingCard() {
        let viewModel = DictationViewModel()
        viewModel.state.approvals.seedPendingForSnapshot(PendingApproval(
            tool: "send_message", instanceID: UUID(), instanceLabel: "Work chat",
            target: "#ops", arguments: ["text": "hi"]))

        XCTAssertTrue(viewModel.handleAssistantEscape())
        XCTAssertNil(viewModel.state.approvals.pending)
    }

    func testEscapeClosesALongAnswer() {
        let viewModel = DictationViewModel()
        viewModel.state.activeDaySummary = DaySummary(
            headline: "Two meetings. First at ten. Then lunch.", detail: "", events: [],
            gaps: [], scopedTo: nil, question: "what's on today")
        viewModel.state.daySummaryAt = Date()

        XCTAssertTrue(viewModel.handleAssistantEscape())
        XCTAssertNil(viewModel.state.activeDaySummary)
    }
}

/// Records what the loop sends — the system prompt and the conversation — then plays
/// a dead model.
private final class PromptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPrompt = ""
    private var recordedText = ""

    var generate: AgentLoop.Generate {
        { [self] text, system in record(text, system); return nil }
    }

    var prompt: String {
        lock.lock()
        defer { lock.unlock() }
        return recordedPrompt
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return recordedText
    }

    private func record(_ text: String, _ system: String) {
        lock.lock()
        defer { lock.unlock() }
        recordedText = text
        recordedPrompt = system
    }
}
