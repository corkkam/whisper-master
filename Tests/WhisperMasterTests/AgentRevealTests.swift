import XCTest

@testable import WhisperMaster

/// What happens to a spoken prompt *after* it is sent.
///
/// This exists because the first version had no answer: a successful send wrote
/// `statusMessage` and nothing else, and `statusMessage` is not a notch surface. The
/// paste is suppressed on this path, so with no band the words simply disappeared and
/// the user had no evidence they had gone anywhere at all.
@MainActor
final class AgentRevealTests: XCTestCase {

    private func controller(sessions: [AgentSession]) -> AgentSurfaceController {
        let controller = AgentSurfaceController(candidates: [])
        controller.seedGlanceForSnapshot(sessions: sessions)
        controller.closeGlance()
        return controller
    }

    func testRevealingASessionOpensTheBandOnIt() {
        let controller = controller(sessions: [
            AgentSession(id: "s1", repo: "whisper-master", state: .running)
        ])
        XCTAssertFalse(controller.isGlanceOpen)

        controller.reveal(sessionID: "s1")

        XCTAssertTrue(controller.isGlanceOpen, "a sent prompt must leave something on screen")
        XCTAssertEqual(controller.openSession?.id, "s1")
    }

    func testARevealedBandStaysWhileTheTurnIsStillRunning() {
        let controller = controller(sessions: [
            AgentSession(id: "s1", repo: "whisper-master", state: .running)
        ])
        controller.reveal(sessionID: "s1")

        // Well past the hold, but the agent is still working: this is exactly the
        // window the user asked to be able to see.
        let later = Date().addingTimeInterval(AgentSurfaceController.revealHold * 10)
        XCTAssertFalse(controller.revealHasExpired(now: later))
    }

    func testARevealedBandGivesTheMenuBarBackOnceTheTurnIsDone() {
        let controller = controller(sessions: [
            AgentSession(id: "s1", repo: "whisper-master", state: .idle)
        ])
        controller.reveal(sessionID: "s1")

        XCTAssertFalse(
            controller.revealHasExpired(now: Date()),
            "it must not vanish the instant it appears")
        let later = Date().addingTimeInterval(AgentSurfaceController.revealHold + 1)
        XCTAssertTrue(controller.revealHasExpired(now: later))
    }

    func testAGlanceTheUserOpenedNeverExpiresOnItsOwn() {
        // A tap is someone choosing to look. Closing it under them because a timer
        // ran out would be the notch deciding it knows better.
        let controller = controller(sessions: [
            AgentSession(id: "s1", repo: "whisper-master", state: .idle)
        ])
        controller.toggleGlance()
        controller.open(sessionID: "s1")

        let muchLater = Date().addingTimeInterval(AgentSurfaceController.revealHold * 100)
        XCTAssertTrue(controller.isGlanceOpen)
        XCTAssertFalse(controller.revealHasExpired(now: muchLater))
    }

    func testTappingAfterARevealClearsTheExpiry() {
        let controller = controller(sessions: [
            AgentSession(id: "s1", repo: "whisper-master", state: .idle)
        ])
        controller.reveal(sessionID: "s1")
        controller.toggleGlance()  // closes
        controller.toggleGlance()  // reopens, deliberately

        let later = Date().addingTimeInterval(AgentSurfaceController.revealHold * 10)
        XCTAssertFalse(
            controller.revealHasExpired(now: later),
            "a deliberate tap must not inherit the receipt's timer")
    }

    func testClosingLetsGoOfTheSessionSoTheNextInterruptCanAttach() {
        let controller = controller(sessions: [
            AgentSession(id: "s1", repo: "whisper-master", state: .idle)
        ])
        controller.reveal(sessionID: "s1")
        controller.closeGlance()

        XCTAssertFalse(controller.isGlanceOpen)
        XCTAssertNil(controller.openSession)
    }

    // MARK: Where a prompt goes

    func testAPromptFollowsTheSessionYouAreReading() {
        let controller = controller(sessions: [
            AgentSession(id: "s1", repo: "alpha", state: .idle),
            AgentSession(id: "s2", repo: "beta", state: .idle),
        ])
        controller.open(sessionID: "s2")
        XCTAssertEqual(controller.promptTarget?.id, "s2")
    }

    func testWithNothingOpenAPromptGoesToTheMostRecentlyActiveSession() {
        // Not the first row: the list is ranked for *reading* (waiting first), and the
        // session you last worked in is the one you mean when you start talking.
        let old = Int64(Date().addingTimeInterval(-600).timeIntervalSince1970 * 1000)
        let recent = Int64(Date().addingTimeInterval(-5).timeIntervalSince1970 * 1000)
        let controller = controller(sessions: [
            AgentSession(id: "old", repo: "alpha", state: .running, turnStartedAt: old),
            AgentSession(id: "recent", repo: "beta", state: .running, turnStartedAt: recent),
        ])
        XCTAssertEqual(controller.promptTarget?.id, "recent")
    }

    func testWithNoSessionsThereIsNoTargetToGuessAt() {
        XCTAssertNil(controller(sessions: []).promptTarget)
    }
}
