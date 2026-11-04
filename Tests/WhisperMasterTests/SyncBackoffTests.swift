import XCTest
@testable import WhisperMaster

/// A failing dashboard must not be hammered by the 0.5 s tick: the request rate is
/// bounded by `SyncBackoff`, and a failed notes pull waits before it tries again.
@MainActor
final class SyncBackoffTests: XCTestCase {
    func testAFailureDoublesTheWaitUpToTheCapAndASuccessResetsIt() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var backoff = SyncBackoff(base: 20, cap: 600)
        XCTAssertTrue(backoff.allows(at: t0), "nothing has run yet")

        backoff.failed(at: t0)
        XCTAssertFalse(backoff.allows(at: t0.addingTimeInterval(19)))
        XCTAssertTrue(backoff.allows(at: t0.addingTimeInterval(20)))

        let waits = (1...8).map { _ -> TimeInterval in
            backoff.failed(at: t0)
            return backoff.notBefore!.timeIntervalSince(t0)
        }
        XCTAssertEqual(waits, [40, 80, 160, 320, 600, 600, 600, 600])

        backoff.succeeded(at: t0)
        XCTAssertEqual(backoff.failures, 0)
        XCTAssertEqual(backoff.notBefore!.timeIntervalSince(t0), 20, "back to the normal debounce")
    }

    /// A long outage cannot overflow the doubling.
    func testThousandsOfFailuresStayAtTheCap() {
        var backoff = SyncBackoff(base: 20, cap: 1800)
        let t0 = Date(timeIntervalSince1970: 0)
        for _ in 0..<5000 { backoff.failed(at: t0) }
        XCTAssertEqual(backoff.notBefore!.timeIntervalSince(t0), 1800)
    }

    /// The request storm: a pull that failed used to be retried on the very next tick.
    func testAFailedPullIsNotRetriedOnTheNextTick() async {
        let store = NotesStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("json"),
            load: false)
        store.activate(userID: "user_a")

        FailingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let client = NotesSyncClient(
            store: store,
            identity: { (userId: "user_a", token: "token") },
            endpoint: URL(string: "https://notes.invalid/api/notes"),
            session: URLSession(configuration: config))

        await client.pull(expectedUserID: "user_a")
        XCTAssertEqual(FailingURLProtocol.requestCount(), 1)
        XCTAssertFalse(client.pullIfNeeded(enabled: true), "a failed pull must wait, not retry at once")
        XCTAssertEqual(FailingURLProtocol.requestCount(), 1)
    }

    /// Same for a push: a failure leaves the items dirty but holds the next try.
    func testAFailedPushIsNotRetriedOnTheNextTick() async {
        let store = NotesStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("json"),
            load: false)
        store.activate(userID: "user_a")
        store.upsertNote(Note(title: "Groceries"))

        FailingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let client = NotesSyncClient(
            store: store,
            identity: { (userId: "user_a", token: "token") },
            endpoint: URL(string: "https://notes.invalid/api/notes"),
            session: URLSession(configuration: config))

        await client.push(ids: store.dirtyIDs)
        XCTAssertEqual(FailingURLProtocol.requestCount(), 1)
        XCTAssertFalse(store.dirtyIDs.isEmpty, "a failed push keeps its items for later")
        XCTAssertFalse(client.syncIfNeeded(enabled: true))
        XCTAssertEqual(FailingURLProtocol.requestCount(), 1)
    }
}

extension SyncBackoffTests {
    /// The failures were the previous account's; the next one syncs at once.
    func testASwitchedAccountDoesNotInheritTheBackoff() async {
        let store = NotesStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("json"),
            load: false)
        store.activate(userID: "user_a")
        FailingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let client = NotesSyncClient(
            store: store,
            identity: { (userId: store.currentUserID ?? "", token: "token") },
            endpoint: URL(string: "https://notes.invalid/api/notes"),
            session: URLSession(configuration: config))

        await client.pull(expectedUserID: "user_a")
        await client.pull(expectedUserID: "user_a")
        XCTAssertEqual(client.pullBackoff.failures, 2)
        XCTAssertFalse(client.pullIfNeeded(enabled: true), "user_a is still backing off")

        store.activate(userID: "user_b")
        XCTAssertTrue(client.pullIfNeeded(enabled: true), "user_b must not wait out user_a's failures")
        // Let that pull finish, so no request outlives the test.
        for _ in 0..<300 where FailingURLProtocol.requestCount() < 3 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(FailingURLProtocol.requestCount(), 3)
    }

    /// Signed out sends nothing, so it must not grow the wait the next sign-in meets.
    func testNoIdentityIsNotAFailure() async {
        let store = NotesStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("json"),
            load: false)
        store.activate(userID: "user_a")
        store.upsertNote(Note(title: "Groceries"))
        let client = NotesSyncClient(
            store: store, identity: { nil },
            endpoint: URL(string: "https://notes.invalid/api/notes"))
        for _ in 0..<3 { await client.push(ids: store.dirtyIDs) }
        XCTAssertEqual(client.pushBackoff.failures, 0)
    }
}

/// Answers every request with HTTP 500 and counts them.
final class FailingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static func reset() { lock.withLock { count = 0 } }
    static func requestCount() -> Int { lock.withLock { count } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
