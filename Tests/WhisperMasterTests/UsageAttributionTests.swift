import XCTest

@testable import WhisperMaster

/// Who a session's usage is credited to, and who a push is labelled for.
///
/// Two regressions guarded here. The finalize's assistant and empty exits used to
/// return before `usageStore.record` was ever reached, so every chord-armed capture
/// was missing from the dashboard; and `push` read the rollups *after* awaiting a
/// token, without re-checking that the account it resolved still owned the store —
/// so one account's numbers could go up under another's id, on an endpoint that is
/// public.
@MainActor
final class UsageAttributionTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-attribution-\(UUID()).json")
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-attribution-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func accounting(_ store: UsageStore) -> DictationViewModel.SessionAccounting {
        DictationViewModel.SessionAccounting(
            store: store,
            appName: "Slack",
            appBundleID: "com.tinyspeck.slackmacgap",
            engineRawValue: "slidingWindow")
    }

    /// A store with one account loaded, so `owner == currentUserID` and records land
    /// in memory where the totals can be read back.
    private func loadedStore(_ user: String, in dir: URL) -> UsageStore {
        let store = UsageStore(
            fileURL: tempURL(),
            load: false,
            fileURLForUser: { dir.appendingPathComponent("\($0).json") })
        store.activate(userID: user)
        return store
    }

    // MARK: - Every exit of the finalize accounts for its session

    // `account` both classifies and records, and returns the kind `stopRecording`
    // switches on to pick its exit — so the recording cannot be dropped without
    // also dropping the exit dispatch. That coupling is the point: the original bug
    // was a missing call, not a wrong record.

    func testAnAssistantCaptureIsClassifiedAndRecorded() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = loadedStore("user_a", in: dir)

        let kind = accounting(store).account(
            transcript: "what's on my calendar today",
            assistantHandled: true,
            duration: 4,
            fixes: .zero,
            owner: "user_a")

        XCTAssertEqual(kind, .assistant)
        XCTAssertEqual(store.totalDictations, 1, "the assistant exit must still record a session")
        XCTAssertEqual(store.totalWords, 5)
    }

    func testAnEmptyCaptureIsClassifiedAndRecordedWithNoWords() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = loadedStore("user_a", in: dir)

        let kind = accounting(store).account(
            transcript: "",
            assistantHandled: false,
            duration: 3,
            fixes: .zero,
            owner: "user_a")

        XCTAssertEqual(kind, .empty)
        XCTAssertEqual(store.totalDictations, 1, "an empty result is a session worth inspecting")
        XCTAssertEqual(store.totalWords, 0)
    }

    func testAnOrdinaryDictationIsClassifiedAsDictation() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = loadedStore("user_a", in: dir)

        let kind = accounting(store).account(
            transcript: "ship it on friday",
            assistantHandled: false,
            duration: 2,
            fixes: .zero,
            owner: "user_a")

        XCTAssertEqual(kind, .dictation)
        XCTAssertEqual(store.totalDictations, 1)
        XCTAssertEqual(store.totalWords, 4)
    }

    func testASessionThatStartedWithNoAccountIsDroppedNotMisattributed() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = loadedStore("user_a", in: dir)

        accounting(store).account(
            transcript: "words nobody owns",
            assistantHandled: false,
            duration: 2,
            fixes: .zero,
            owner: nil)

        XCTAssertEqual(
            store.totalDictations, 0,
            "with no owner there is no account to credit — it must not land on whoever is loaded")
    }

    // MARK: - A push is never labelled with an account it did not read

    func testAPushWhoseAccountChangedMidFlightSendsNothing() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let today = StreakCalculator.dayKey(for: Date())
        let fileForUser: (String) -> URL = { dir.appendingPathComponent("\($0).json") }

        let store = UsageStore(fileURL: tempURL(), load: false, fileURLForUser: fileForUser)

        // B has usage for today on disk, so that after the swap there is something
        // real to send. Without that, an empty rollup set would short-circuit the
        // push anyway and the test would pass with or without the guard.
        store.activate(userID: "user_b")
        store.record(
            DictationRecord(
                timestamp: Date(), wordCount: 99, durationSeconds: 9,
                appName: "Mail", appBundleID: "com.apple.mail",
                engineRawValue: "slidingWindow", fixes: .zero))

        store.activate(userID: "user_a")
        store.record(
            DictationRecord(
                timestamp: Date(), wordCount: 5, durationSeconds: 5,
                appName: "Slack", appBundleID: "com.tinyspeck.slackmacgap",
                engineRawValue: "slidingWindow", fixes: .zero))
        XCTAssertTrue(store.dirtyDays.contains(today))

        CapturingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]

        let client = UsageSyncClient(
            store: store,
            identity: {
                // `identity()` awaits a fresh token; the 0.5 s auth reconcile lands
                // in that window and repoints the store at B, while the id already
                // resolved is still A's.
                store.activate(userID: "user_b")
                return (userId: "user_a", token: "token")
            },
            endpoint: URL(string: "https://usage.invalid/api/usage"),
            session: URLSession(configuration: config))

        await client.push(days: [today])

        XCTAssertEqual(
            CapturingURLProtocol.requestCount(), 0,
            "B's rollups must never be posted under A's id — the endpoint is public")
    }

    func testAPushWhoseAccountIsUnchangedStillSends() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let today = StreakCalculator.dayKey(for: Date())
        let store = loadedStore("user_a", in: dir)
        store.record(
            DictationRecord(
                timestamp: Date(), wordCount: 5, durationSeconds: 5,
                appName: "Slack", appBundleID: "com.tinyspeck.slackmacgap",
                engineRawValue: "slidingWindow", fixes: .zero))

        CapturingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]

        let client = UsageSyncClient(
            store: store,
            identity: { (userId: "user_a", token: "token") },
            endpoint: URL(string: "https://usage.invalid/api/usage"),
            session: URLSession(configuration: config))

        await client.push(days: [today])

        XCTAssertEqual(
            CapturingURLProtocol.requestCount(), 1,
            "the guard must only stop a mismatch, not every push")
    }
}

/// Counts requests instead of making them, so a test can assert that nothing was
/// sent. Answers 200 so the success path is exercised when a send is expected.
final class CapturingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
