import XCTest

@testable import WhisperMaster

/// The interruption policy for sessions the band is not watching.
///
/// Every test here is a rule about *not* interrupting. The feature is easy; the
/// discipline is the whole product.
final class AgentAttentionTests: XCTestCase {

    private func session(
        _ id: String, _ state: KunaiWire.SessionState, repo: String = "repo"
    ) -> AgentSession {
        AgentSession(id: id, repo: repo, state: state)
    }

    func testASessionAlreadyWaitingWhenWeFirstSeeItIsNotNews() {
        // Otherwise every launch announced every blocked session, and the first thing
        // the app did after opening was interrupt you about something old.
        var attention = AgentAttention()
        let event = attention.update(
            sessions: [session("a", .awaitingPermission)], watching: nil)
        XCTAssertNil(event)
    }

    func testASessionThatBlocksAfterWeHaveSeenItIsAnnouncedOnce() {
        var attention = AgentAttention()
        _ = attention.update(sessions: [session("a", .running)], watching: nil)

        let first = attention.update(
            sessions: [session("a", .awaitingPermission, repo: "kunai")], watching: nil)
        XCTAssertEqual(first?.kind, .needsYou)
        XCTAssertEqual(first?.line, "kunai needs you")

        // Still blocked on the next poll, and the one after: silence.
        XCTAssertNil(
            attention.update(sessions: [session("a", .awaitingPermission)], watching: nil))
        XCTAssertNil(
            attention.update(sessions: [session("a", .awaitingPermission)], watching: nil))
    }

    func testTheSameSessionCanAnnounceAgainAfterItIsAnswered() {
        var attention = AgentAttention()
        _ = attention.update(sessions: [session("a", .running)], watching: nil)
        _ = attention.update(sessions: [session("a", .awaitingPermission)], watching: nil)
        // Answered, back to work, blocked again — that is a new event.
        _ = attention.update(sessions: [session("a", .running)], watching: nil)
        let again = attention.update(
            sessions: [session("a", .awaitingPermission)], watching: nil)
        XCTAssertEqual(again?.kind, .needsYou)
    }

    func testTheSessionOnScreenIsNeverAnnounced() {
        // Its ask and its reply already have their own surfaces. Saying it twice is
        // how a surface starts to nag.
        var attention = AgentAttention()
        _ = attention.update(sessions: [session("a", .running)], watching: "a")
        XCTAssertNil(
            attention.update(sessions: [session("a", .awaitingPermission)], watching: "a"))
        XCTAssertNil(attention.update(sessions: [session("a", .idle)], watching: "a"))
    }

    func testAFinishedBackgroundTurnIsAnnounced() {
        var attention = AgentAttention()
        _ = attention.update(sessions: [session("a", .running, repo: "landing-page")], watching: nil)
        let event = attention.update(
            sessions: [session("a", .idle, repo: "landing-page")], watching: nil)
        XCTAssertEqual(event?.kind, .finished)
        XCTAssertEqual(event?.line, "landing-page finished")
        XCTAssertEqual(event?.hint, "Tap to read")
    }

    func testAnIdleSessionThatNeverRanIsNotAFinish() {
        var attention = AgentAttention()
        _ = attention.update(sessions: [session("a", .idle)], watching: nil)
        XCTAssertNil(attention.update(sessions: [session("a", .idle)], watching: nil))
    }

    func testAPermissionOutranksAFinishInTheSamePass() {
        // Two things at once is still one interruption, and the blocked machine is
        // the one that cannot continue without you.
        var attention = AgentAttention()
        _ = attention.update(
            sessions: [session("a", .running, repo: "one"), session("b", .running, repo: "two")],
            watching: nil)
        let event = attention.update(
            sessions: [
                session("a", .idle, repo: "one"),
                session("b", .awaitingPermission, repo: "two"),
            ],
            watching: nil)
        XCTAssertEqual(event?.kind, .needsYou)
        XCTAssertEqual(event?.sessionID, "b")
    }

    func testASessionKunaiStopsListingIsForgotten() {
        // Ids must not accumulate for the life of the process.
        var attention = AgentAttention()
        _ = attention.update(sessions: [session("a", .running)], watching: nil)
        _ = attention.update(sessions: [], watching: nil)
        // Seen fresh again, it is once more a first sighting, so it stays silent.
        XCTAssertNil(
            attention.update(sessions: [session("a", .awaitingPermission)], watching: nil))
    }
}
