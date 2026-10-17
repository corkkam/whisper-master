import XCTest

@testable import WhisperMaster

/// A quit or a crash mid-meeting leaves both sides of the call in the temporary
/// folder. `removeLeftovers` is the only thing that ever removes them.
final class MeetingAudioRecorderTests: XCTestCase {
    private var parent: URL!

    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAudioRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
    }

    private func folder(_ name: String, writtenAt date: Date) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let track = folder.appendingPathComponent("others.caf")
        try Data([0, 1, 2]).write(to: track)
        for url in [track, folder] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        return folder
    }

    func testAnAbandonedRecordingIsRemoved() throws {
        let now = Date()
        let old = try folder("\(MeetingAudioRecorder.directoryPrefix)old", writtenAt: now.addingTimeInterval(-3600))
        MeetingAudioRecorder.removeLeftovers(in: parent, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testARecordingStillBeingWrittenIsKept() throws {
        let now = Date()
        let live = try folder("\(MeetingAudioRecorder.directoryPrefix)live", writtenAt: now.addingTimeInterval(-30))
        MeetingAudioRecorder.removeLeftovers(in: parent, now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    }

    func testOtherFoldersAreNeverTouched() throws {
        let now = Date()
        let other = try folder("SomethingElse", writtenAt: now.addingTimeInterval(-86_400))
        MeetingAudioRecorder.removeLeftovers(in: parent, now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}
