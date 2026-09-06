import XCTest

@testable import WhisperMaster

/// kunai replays the session's ring buffer on attach: every prior turn's frames
/// arrive down the socket before the live ones. Treating those as live is what made
/// the band re-announce every historical turn — reply and working flashing once per
/// old turn — on the first dictation. `hello.high_seq` is the boundary, and these
/// pin what may cross it.
@MainActor
final class AgentReplayGatingTests: XCTestCase {

    private func decode(_ json: String) throws -> KunaiWire.Event {
        try JSONDecoder().decode(KunaiWire.Event.self, from: Data(json.utf8))
    }

    /// A controller attached to one session, with the hello marking seq 50 as the
    /// history/live boundary.
    private func attached() throws -> AgentSurfaceController {
        let controller = AgentSurfaceController(candidates: [])
        controller.seedForSnapshot(
            ask: .approval(
                AgentApproval(requestID: "seed", tool: "Bash", headline: "x", detail: "r")),
            sessions: [AgentSession(id: "s1", repo: "r", state: .running)])
        controller.resolve(controller.ask!, allow: false)  // clear the seed ask
        try controller.apply(decode(#"{"seq":51,"t":"hello","id":"s1","epoch":"e1","high_seq":50}"#))
        return controller
    }

    func testAReplayedResultDoesNotAnnounceAFinishedTurn() throws {
        let controller = try attached()
        try controller.apply(decode(
            #"{"seq":40,"t":"assistant","blocks":[{"type":"text","text":"Old reply."}]}"#))
        try controller.apply(decode(#"{"seq":41,"t":"result","duration_ms":5000}"#))

        XCTAssertNil(controller.lastReply, "a turn that finished before attach already had its banner")
        XCTAssertNil(controller.lastReplyAt)
    }

    func testALiveResultStillAnnounces() throws {
        let controller = try attached()
        try controller.apply(decode(
            #"{"seq":52,"t":"assistant","blocks":[{"type":"text","text":"Fresh reply."}]}"#))
        try controller.apply(decode(#"{"seq":53,"t":"result","duration_ms":5000}"#))

        XCTAssertEqual(controller.lastReply, "Fresh reply.")
        XCTAssertNotNil(controller.lastReplyAt)
    }

    func testAReplayedPermissionDoesNotRaiseAStaleConsentCard() throws {
        // Its resolution is a few frames behind it in the same replay; raising it
        // flashes a card for a question nobody is asking.
        let controller = try attached()
        try controller.apply(decode(
            #"{"seq":30,"t":"permission","request_id":"old","tool_name":"Bash","input":{"command":"ls"}}"#))
        XCTAssertNil(controller.ask)
    }

    func testAPendingAskOnHelloIsRaisedHoweverOldItsSequenceIs() throws {
        // `pending` is kunai saying "still waiting" — age is irrelevant.
        let controller = AgentSurfaceController(candidates: [])
        controller.seedForSnapshot(
            ask: .approval(
                AgentApproval(requestID: "seed", tool: "Bash", headline: "x", detail: "r")),
            sessions: [AgentSession(id: "s1", repo: "r", state: .awaitingPermission)])
        controller.resolve(controller.ask!, allow: false)
        try controller.apply(decode(
            """
            {"seq":51,"t":"hello","id":"s1","epoch":"e1","high_seq":50,
             "pending":[{"seq":30,"t":"permission","request_id":"waiting","tool_name":"Bash",
                         "input":{"command":"swift test"}}]}
            """))
        XCTAssertEqual(controller.ask?.requestID, "waiting")
    }

    func testReplayedHistoryStillFeedsTheLogForContext() throws {
        // The gate is on announcements, not on memory: the replayed prompt is
        // exactly what the expanded band's question line needs.
        let controller = try attached()
        try controller.apply(decode(#"{"seq":39,"t":"user","text":"earlier question"}"#))
        XCTAssertEqual(controller.log.lastUserPrompt, "earlier question")
        XCTAssertNil(controller.lastReply)
    }

    func testAnUnsequencedFrameCountsAsLive() throws {
        // seq 0 means kunai didn't number it; swallowing it as "history" would
        // silently drop a real event.
        let controller = try attached()
        try controller.apply(decode(
            #"{"t":"assistant","blocks":[{"type":"text","text":"Unsequenced."}]}"#))
        XCTAssertEqual(controller.lastReply, "Unsequenced.")
    }
}
