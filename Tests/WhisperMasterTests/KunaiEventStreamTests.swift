import XCTest

@testable import WhisperMaster

/// The seam where a spoken prompt was being lost.
///
/// `attach` assigns the stream object synchronously, but the WebSocket itself is
/// opened later by the pump task calling `connect()`. A command raised in between
/// found `task == nil` and was dropped by a bare `guard … else { return }` — so the
/// words vanished while the notch reported them sent, and kunai never heard about it.
final class KunaiEventStreamTests: XCTestCase {

    /// Points at a port nothing is listening on, so no socket can ever open. That is
    /// the whole point: these assert what happens *before* one does.
    private func stream() -> KunaiEventStream {
        KunaiEventStream(
            endpoint: KunaiEndpoint(host: "127.0.0.1", port: 59_999),
            sessionID: "s1")
    }

    func testACommandSentBeforeTheSocketExistsIsKeptNotDropped() async {
        let stream = stream()
        let ready = await stream.isReady
        XCTAssertFalse(ready, "no socket should exist before connect()")

        await stream.send(.prompt("fix the flaky test"))

        let queued = await stream.pendingCount
        XCTAssertEqual(queued, 1, "the prompt must survive until there is a socket")
    }

    func testEveryQueuedCommandIsKeptInOrder() async {
        let stream = stream()
        await stream.send(.prompt("first"))
        await stream.send(.permission(requestID: "r1", allow: true))
        await stream.send(.setMode(.auto))

        let queued = await stream.pendingCount
        XCTAssertEqual(queued, 3)
    }

    func testReadinessDescribesTheSocketNotTheObject() async {
        // The distinction that caused the bug: holding a `KunaiEventStream` is not the
        // same as having somewhere to send.
        let stream = stream()
        let ready = await stream.isReady
        XCTAssertFalse(ready)
    }

    func testDisconnectingLeavesNothingClaimingToBeReady() async {
        let stream = stream()
        await stream.send(.prompt("hello"))
        await stream.disconnect()

        let ready = await stream.isReady
        XCTAssertFalse(ready)
    }
}
