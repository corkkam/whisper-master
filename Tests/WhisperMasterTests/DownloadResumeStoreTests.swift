import XCTest
@testable import WhisperMaster

/// `DownloadResumeStore` is the persistent bookkeeping that lets a model
/// download survive an app quit (URL→destination map) and a dropped connection
/// (resume data). These exercise the on-disk round-trips in a temp directory.
final class DownloadResumeStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let url = URL(string: "https://dl.corkkam.com/models/Qwen2.5-3B-Instruct-4bit.zip")!

    func testNoteAndReadDestination() {
        let store = DownloadResumeStore(root: root)
        let dest = root.appendingPathComponent("Qwen.zip")
        XCTAssertNil(store.destination(for: url))
        store.note(url: url, destination: dest)
        XCTAssertEqual(store.destination(for: url)?.path, dest.path)
    }

    /// The map must survive being read by a *fresh* store instance — that's the
    /// whole point: a different launch resolves where a finished download goes.
    func testDestinationPersistsAcrossInstances() {
        let dest = root.appendingPathComponent("Qwen.zip")
        DownloadResumeStore(root: root).note(url: url, destination: dest)
        XCTAssertEqual(DownloadResumeStore(root: root).destination(for: url)?.path, dest.path)
    }

    func testResumeDataRoundTripAndClear() {
        let store = DownloadResumeStore(root: root)
        let token = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertNil(store.resumeData(for: url))
        store.saveResumeData(token, for: url)
        XCTAssertEqual(store.resumeData(for: url), token)
        store.clearResumeData(for: url)
        XCTAssertNil(store.resumeData(for: url))
    }

    /// Resume data is keyed by a launch-stable hash of the URL, so a new instance
    /// (i.e. a later launch) finds the same token.
    func testResumeDataPersistsAcrossInstances() {
        let token = Data([1, 2, 3, 4, 5])
        DownloadResumeStore(root: root).saveResumeData(token, for: url)
        XCTAssertEqual(DownloadResumeStore(root: root).resumeData(for: url), token)
    }

    func testForgetClearsBothMapAndResumeData() {
        let store = DownloadResumeStore(root: root)
        store.note(url: url, destination: root.appendingPathComponent("Qwen.zip"))
        store.saveResumeData(Data([9]), for: url)
        store.forget(url: url)
        XCTAssertNil(store.destination(for: url))
        XCTAssertNil(store.resumeData(for: url))
    }

    /// Two archives that share a filename but differ by URL must not collide.
    func testDistinctURLsDoNotCollide() {
        let store = DownloadResumeStore(root: root)
        let other = URL(string: "https://example.com/other/Qwen2.5-3B-Instruct-4bit.zip")!
        store.saveResumeData(Data([1]), for: url)
        store.saveResumeData(Data([2]), for: other)
        XCTAssertEqual(store.resumeData(for: url), Data([1]))
        XCTAssertEqual(store.resumeData(for: other), Data([2]))
    }
}
