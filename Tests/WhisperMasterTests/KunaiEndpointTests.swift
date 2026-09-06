import XCTest

@testable import WhisperMaster

/// Finding the server. This is where the first version was wrong: it assumed
/// loopback HTTP, and a real install with a tailnet binds the tailnet IP with a
/// minted certificate instead, so nothing answers on 127.0.0.1 at all.
final class KunaiEndpointTests: XCTestCase {

    func testTheURLFileKunaiWritesIsParsedIncludingItsNewline() {
        // kunai writes `<publicURL>\n` to `<dataDir>/url` on every boot. Carrying the
        // newline into the host is how the whole address quietly stops resolving.
        let url = KunaiEndpoint.normalized("https://host.tail75ba2a.ts.net:8444\n")
        XCTAssertEqual(url?.host, "host.tail75ba2a.ts.net")
        XCTAssertEqual(url?.port, 8444)
        XCTAssertEqual(url?.scheme, "https")
    }

    func testNonHTTPAddressesAreRefused() {
        XCTAssertNil(KunaiEndpoint.normalized(""))
        XCTAssertNil(KunaiEndpoint.normalized("   \n "))
        XCTAssertNil(KunaiEndpoint.normalized("file:///etc/passwd"))
        XCTAssertNil(KunaiEndpoint.normalized("not a url"))
    }

    func testATLSInstallGetsASecureSocket() {
        // Asking for `ws` against an `https` server fails the upgrade rather than
        // silently downgrading, so the scheme has to follow the base URL.
        let secure = KunaiEndpoint(
            baseURL: URL(string: "https://host.ts.net:8444")!)
        XCTAssertEqual(secure.socket(sessionID: "s1", since: 0)?.scheme, "wss")

        let local = KunaiEndpoint(host: "127.0.0.1", port: 8443)
        XCTAssertEqual(local.socket(sessionID: "s1", since: 0)?.scheme, "ws")
    }

    func testTheResumeMarkRidesOnTheSocketURL() {
        let endpoint = KunaiEndpoint(host: "127.0.0.1", port: 8443)
        let url = endpoint.socket(sessionID: "abc", since: 42)
        XCTAssertEqual(url?.path, "/ws/app/abc")
        XCTAssertEqual(url?.query, "since=42")
    }

    func testAFreshAttachAsksForNoResumePoint() {
        // `since=0` would be a lie about having seen frame zero; kunai's default is
        // "everything you have", which is what an unseen session wants.
        let endpoint = KunaiEndpoint(host: "127.0.0.1", port: 8443)
        XCTAssertNil(endpoint.socket(sessionID: "abc", since: 0)?.query)
    }

    func testCandidatesAlwaysEndWithTheDocumentedDefault() {
        // Whatever discovery finds, loopback stays the last thing tried, so a machine
        // that has never run kunai still has something to probe.
        let candidates = KunaiEndpoint.candidates
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(
            candidates.contains { $0.baseURL.host == "127.0.0.1" },
            "the default loopback endpoint must always be a candidate")
    }

    func testCandidatesAreDeduplicated() {
        // A machine with one install must not probe the same address twice per poll.
        let addresses = KunaiEndpoint.candidates.map(\.baseURL.absoluteString)
        XCTAssertEqual(addresses.count, Set(addresses).count)
    }

    func testAPIPathsHangOffTheDiscoveredBase() {
        let endpoint = KunaiEndpoint(baseURL: URL(string: "https://host.ts.net:8444")!)
        XCTAssertEqual(
            endpoint.api("api/sessions")?.absoluteString,
            "https://host.ts.net:8444/api/sessions")
    }
}
