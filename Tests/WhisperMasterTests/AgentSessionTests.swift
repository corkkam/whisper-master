import XCTest

@testable import WhisperMaster

/// The glance row: which codebase, what it is doing, and what order they appear in.
final class AgentSessionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func session(
        _ id: String, repo: String, state: KunaiWire.SessionState,
        startedSecondsAgo: Int? = nil
    ) -> AgentSession {
        AgentSession(
            id: id, repo: repo, state: state,
            turnStartedAt: startedSecondsAgo.map {
                Int64((now.timeIntervalSince1970 - Double($0)) * 1000)
            })
    }

    func testTheRepoIsTheLastPathComponent() {
        XCTAssertEqual(
            AgentSession.repoName(fromPath: "/Users/x/coding/whisper-master"), "whisper-master")
        XCTAssertEqual(
            AgentSession.repoName(fromPath: "/Users/x/coding/kunai/"), "kunai",
            "a trailing slash must not produce an empty name")
        XCTAssertEqual(AgentSession.repoName(fromPath: ""), "session")
    }

    func testARunningTurnReportsHowLongNotJustThatItIs() {
        // Twenty seconds is a session thinking and twenty minutes is one worth
        // looking at. Only the elapsed form tells those apart.
        let quick = session("a", repo: "r", state: .running, startedSecondsAgo: 17)
        XCTAssertEqual(quick.statusLabel(now: now), "Working 17s")

        let slow = session("b", repo: "r", state: .running, startedSecondsAgo: 20 * 60)
        XCTAssertEqual(slow.statusLabel(now: now), "Working 20m")
    }

    func testARunningTurnWithNoStartTimeStillReadsHonestly() {
        let unknown = session("a", repo: "r", state: .running)
        XCTAssertEqual(unknown.statusLabel(now: now), "Working")
    }

    func testWaitingIsTheOnlyStatusThatAsksForSomething() {
        XCTAssertEqual(
            session("a", repo: "r", state: .awaitingPermission).statusLabel(now: now),
            "Needs you")
        XCTAssertTrue(session("a", repo: "r", state: .awaitingPermission).isWaiting)
    }

    func testTheGlancePutsWhatNeedsYouFirstThenTheLongestRunningTurn() {
        let ranked = [
            session("idle", repo: "c", state: .idle),
            session("new", repo: "b", state: .running, startedSecondsAgo: 5),
            session("old", repo: "a", state: .running, startedSecondsAgo: 600),
            session("ask", repo: "d", state: .awaitingPermission),
        ].rankedForGlance()

        XCTAssertEqual(ranked.map(\.id), ["ask", "old", "new", "idle"])
    }

    func testOrderingIsStableSoTheListDoesNotShuffleBetweenTicks() {
        // The glance repaints on a poll. Ties have to break deterministically or the
        // rows swap places under the pointer.
        let a = session("s1", repo: "alpha", state: .idle)
        let b = session("s2", repo: "beta", state: .idle)
        XCTAssertEqual([b, a].rankedForGlance().map(\.id), [a, b].rankedForGlance().map(\.id))
    }

    func testAnIdleSessionSaysWhatItIsWaitingFor() {
        XCTAssertEqual(
            session("a", repo: "r", state: .idle).subtitle, "Waiting for your next prompt")
    }

    func testActivityOutranksTheSessionTitle() {
        var live = session("a", repo: "r", state: .running)
        live.title = "Fix the audio tests"
        live.activity = "Editing NotchGlow.swift"
        XCTAssertEqual(live.subtitle, "Editing NotchGlow.swift")
    }

    func testMetaMapsStraightOntoARow() {
        let meta = KunaiWire.SessionMeta(
            id: "s1", cwd: "/Users/x/whisper-master", title: "Audio fix",
            state: "awaiting_permission")
        let row = AgentSession(meta: meta)
        XCTAssertEqual(row.repo, "whisper-master")
        XCTAssertEqual(row.state, .awaitingPermission)
        XCTAssertEqual(row.mode, .ask, "a session's mode is unknown until its socket says otherwise")
    }

    func testAZeroTurnStartIsTreatedAsNotRunning() {
        // kunai zeroes it the moment a turn ends, so it can never outlive the work it
        // measures. Zero must not become 1970.
        let meta = KunaiWire.SessionMeta(
            id: "s1", cwd: "/x/r", title: "", state: "idle", turnStartedAt: 0)
        XCTAssertNil(AgentSession(meta: meta).turnStartedAt)
    }
}
