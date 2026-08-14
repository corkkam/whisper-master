import XCTest
@testable import WhisperMaster

/// The wire contract of notes sync, pinned as tests rather than comments: the
/// verbatim transcript and the audio never cross the network, and a note is never
/// posted under the wrong account. Mirrors `UsageAttributionTests`' harness.
@MainActor
final class NotesSyncClientTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    }

    private func loadedStore(_ userID: String) -> NotesStore {
        let store = NotesStore(fileURL: tempURL(), load: false)
        store.activate(userID: userID)
        return store
    }

    /// A dictated note carries the raw transcript and the recording filename on
    /// device; neither may be uploaded — the dashboard stores only title/body/dates.
    func testAPushCarriesTitleAndBodyButNeverTheTranscriptOrAudio() async {
        let store = loadedStore("user_a")
        store.upsertNote(Note(
            title: "Groceries",
            body: "milk and eggs",
            transcript: "SECRET_TRANSCRIPT_CANARY get milk uh eggs",
            audio: NoteAudio(fileName: "SECRET_AUDIO_CANARY.wav", durationMs: 4200)))

        BodyCapturingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BodyCapturingURLProtocol.self]

        let client = NotesSyncClient(
            store: store,
            identity: { (userId: "user_a", token: "token") },
            endpoint: URL(string: "https://notes.invalid/api/notes"),
            session: URLSession(configuration: config))

        await client.push(ids: store.dirtyIDs)

        let body = BodyCapturingURLProtocol.lastBodyString() ?? ""
        XCTAssertFalse(body.isEmpty, "the push should have sent a body")
        XCTAssertTrue(body.contains("Groceries"), "title is what sync is for")
        XCTAssertFalse(body.contains("SECRET_TRANSCRIPT_CANARY"),
                       "the verbatim transcript must never leave the Mac")
        XCTAssertFalse(body.contains("SECRET_AUDIO_CANARY"),
                       "the audio filename must never leave the Mac")
    }

    /// The account can switch during the `identity()` await; a note resolved for A
    /// must not be posted while the store now points at B.
    func testAPushUnderAMismatchedAccountSendsNothing() async {
        let store = loadedStore("user_a")
        store.upsertNote(Note(title: "A's note", transcript: "private"))

        BodyCapturingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BodyCapturingURLProtocol.self]

        let client = NotesSyncClient(
            store: store,
            identity: {
                // The reconcile tick repoints the store at B inside the await, while
                // the id already resolved is still A's.
                store.activate(userID: "user_b")
                return (userId: "user_a", token: "token")
            },
            endpoint: URL(string: "https://notes.invalid/api/notes"),
            session: URLSession(configuration: config))

        await client.push(ids: store.dirtyIDs)

        XCTAssertEqual(BodyCapturingURLProtocol.requestCount(), 0,
                       "a note must never be posted under a mismatched account")
    }

    /// The guard only stops a mismatch — an unchanged account still syncs.
    func testAPushWhoseAccountIsUnchangedStillSends() async {
        let store = loadedStore("user_a")
        store.upsertNote(Note(title: "keep me"))

        BodyCapturingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BodyCapturingURLProtocol.self]

        let client = NotesSyncClient(
            store: store,
            identity: { (userId: "user_a", token: "token") },
            endpoint: URL(string: "https://notes.invalid/api/notes"),
            session: URLSession(configuration: config))

        await client.push(ids: store.dirtyIDs)

        XCTAssertEqual(BodyCapturingURLProtocol.requestCount(), 1)
    }
}

/// Captures the request body (reading `httpBodyStream`, which is where URLSession
/// puts a set `httpBody` by the time a protocol sees it) so a test can assert what
/// actually went on the wire. Answers 200 so the success path runs.
final class BodyCapturingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var lastBody: Data?

    static func reset() {
        lock.lock(); count = 0; lastBody = nil; lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    static func lastBodyString() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastBody.flatMap { String(data: $0, encoding: .utf8) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.drain(request.httpBodyStream)
        Self.lock.lock()
        Self.count += 1
        Self.lastBody = body
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
