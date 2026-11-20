import XCTest

@testable import WhisperMaster

/// A cancel (Escape, sign-out) and a connector write: a cancel never starts a write,
/// never raises a card, and never cuts a write already on the wire.
@MainActor
final class ToolRouterCancelTests: XCTestCase {
    private let send = ToolCall(tool: "send_message", arguments: ["channel": "#ops", "text": "hi"])

    /// The task a test cancels from inside a callback.
    private final class Handle: @unchecked Sendable {
        var task: Task<ToolResult, Never>?
    }

    private func store(granted: Bool) -> ConnectorInstanceStore {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        let slack = store.add(ConnectorInstance(kind: .slack, label: "Work chat", identity: "team"))
        if granted { store.addGrant(Grant(tool: "send_message", instanceID: slack.id, target: "#ops")) }
        return store
    }

    private func router(_ store: ConnectorInstanceStore, writer: StubWriter,
                        approval: @escaping (PendingApproval) async -> ApprovalOutcome) -> ToolRouter {
        var router = ToolRouter(store: store, requestApproval: approval)
        router.writeProvider = { _ in writer }
        return router
    }

    func testACancelledRunRaisesNoCardAndSendsNothing() async {
        let writer = StubWriter()
        var asked = false
        let router = router(store(granted: false), writer: writer) { _ in asked = true; return .allowedOnce }

        let task = Task { await router.run(send) }
        task.cancel()
        let result = await task.value

        XCTAssertFalse(asked, "no card after a cancel")
        XCTAssertEqual(writer.calls, 0)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.text, ToolRouter.stoppedBeforeWrite)
    }

    /// Escape denies the card, but a sign-out cancel can land while it waits and the
    /// user can still tap Once: the write must not go out.
    func testACancelWhileTheCardWaitsStopsTheWrite() async {
        let writer = StubWriter()
        let handle = Handle()
        let router = router(store(granted: false), writer: writer) { _ in
            handle.task?.cancel()
            return .allowedOnce
        }

        let task = Task { await router.run(send) }
        handle.task = task
        let result = await task.value

        XCTAssertEqual(writer.calls, 0)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.text, ToolRouter.stoppedBeforeWrite)
    }

    /// The request has started: the server may have taken it, so it runs to the end
    /// and the result says it was sent.
    func testAWriteAlreadyStartedIsNotCutByACancel() async {
        let writer = StubWriter()
        let handle = Handle()
        writer.onWrite = { handle.task?.cancel() }
        let router = router(store(granted: true), writer: writer) { _ in .denied }

        let task = Task { await router.run(send) }
        handle.task = task
        let result = await task.value

        XCTAssertEqual(writer.calls, 1)
        XCTAssertFalse(writer.sawCancel, "the write's own task is not cancelled")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.authorization, .standingGrant)
    }

    /// …and a write that came back ok is a receipt, not "nothing was created".
    func testAWriteThatCameBackOkCountsAsDoneAfterACancel() async {
        let writer = StubWriter()
        let handle = Handle()
        writer.onWrite = { handle.task?.cancel() }
        let notes = NotesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-write-\(UUID()).json"), load: false)
        let commands = CommandToolRouter(
            local: LocalToolRunner(notes: notes),
            connectors: router(store(granted: true), writer: writer) { _ in .denied })

        let task = Task { await commands.run(send) }
        handle.task = task
        _ = await task.value

        XCTAssertTrue(commands.didCreateSomething)
        XCTAssertEqual(commands.executed, ["send_message"])
    }

    /// A read cut by a cancel says nothing about the connection.
    func testACancelledReadMarksNoErrorOnTheConnection() async {
        let store = store(granted: false)
        let router = ToolRouter(store: store, requestApproval: { _ in .denied })

        let task = Task { await router.run(ToolCall(tool: "list_messages", arguments: [:])) }
        task.cancel()
        _ = await task.value

        XCTAssertNil(store.ordered.first?.lastError)
    }
}

/// Stands in for a provider's network write and records what it saw.
@MainActor
private final class StubWriter: WriteCapableProvider {
    nonisolated static var kind: ConnectorKind { .slack }
    var onWrite: () -> Void = {}
    private(set) var calls = 0
    private(set) var sawCancel = false

    nonisolated func validate(_ credential: ConnectorCredential,
                              config: ConnectorConfig) async -> ValidationResult {
        .invalid("Not used.")
    }

    func performWrite(tool: String, arguments: [String: String],
                      instance: ConnectorInstance) async -> WriteResult {
        calls += 1
        onWrite()
        // A real request would be cut here if its task were the cancelled one.
        try? await Task.sleep(nanoseconds: 20_000_000)
        sawCancel = Task.isCancelled
        return .done("Sent to #ops.")
    }
}
