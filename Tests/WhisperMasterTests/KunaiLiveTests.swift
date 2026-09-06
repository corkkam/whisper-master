import XCTest

@testable import WhisperMaster

/// A bench, not a unit test: it talks to a **real kunai** on this machine.
///
/// Opt-in via `KUNAI_LIVE=1`, and it **skips rather than fails** when the variable
/// is absent or no server answers, so CI and a fresh clone stay green. Same posture
/// as `AudioReplayTests`, and for the same reason: the thing worth verifying here is
/// the seam with somebody else's process, which no fixture can stand in for.
///
///     KUNAI_LIVE=1 swift test --filter KunaiLiveTests
final class KunaiLiveTests: XCTestCase {

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["KUNAI_LIVE"] == "1"
    }

    func testDiscoveryFindsTheServerThisMachineActuallyRuns() async throws {
        try XCTSkipUnless(isEnabled, "set KUNAI_LIVE=1 to run against a real kunai")

        let client = KunaiRESTClient()
        let sessions = await client.sessions()
        let reachable = await client.isReachable
        let active = await client.active

        try XCTSkipUnless(reachable, "no kunai answered on any candidate address")

        // The failure this exists to catch: assuming loopback HTTP when a tailnet
        // install binds the tailnet IP with a minted certificate.
        let address = try XCTUnwrap(active?.baseURL.absoluteString)
        print("kunai discovered at \(address) with \(sessions.count) session(s)")

        XCTAssertTrue(
            ["http", "https"].contains(active?.baseURL.scheme ?? ""),
            "discovered address must be an http(s) URL")

        // Every row has to survive decoding, whatever kunai is running. A session
        // that decodes to an empty id would render as an unclickable blank row.
        for meta in sessions {
            XCTAssertFalse(meta.id.isEmpty, "a session with no id cannot be attached to")
            let row = AgentSession(meta: meta)
            XCTAssertFalse(row.repo.isEmpty, "every row needs a name to lead with")
            XCTAssertFalse(row.statusLabel(now: Date()).isEmpty)
        }
    }

    func testTheSocketURLIsBuiltForWhicheverServerAnswered() async throws {
        try XCTSkipUnless(isEnabled, "set KUNAI_LIVE=1 to run against a real kunai")

        let client = KunaiRESTClient()
        _ = await client.sessions()
        // Read the actor's state into locals first: `XCTSkipUnless` and `XCTUnwrap`
        // take autoclosures, which cannot await.
        let reachable = await client.isReachable
        let discovered = await client.active
        try XCTSkipUnless(reachable, "no kunai answered")

        let active = try XCTUnwrap(discovered)
        let socket = try XCTUnwrap(active.socket(sessionID: "probe", since: 7))
        // A TLS server needs wss; asking for ws there fails the upgrade.
        XCTAssertEqual(socket.scheme, active.baseURL.scheme == "https" ? "wss" : "ws")
        XCTAssertEqual(socket.host, active.baseURL.host)
        XCTAssertEqual(socket.port, active.baseURL.port)
        print("socket would open at \(socket.absoluteString)")
    }
}
