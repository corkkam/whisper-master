import XCTest

@testable import WhisperMaster

/// Helpers that write events.jsonl in a temp folder. Shared by the Crew tests.
enum CrewTestFiles {
    static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crew-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func line(_ event: String, agent: String = "a", project: String = "/p", second: Int = 0, kind: String? = nil) -> String {
        let ts = String(format: "2026-11-27T14:%02d:%02d.000Z", second / 60, second % 60)
        let kindText = kind.map { "\"\($0)\"" } ?? "null"
        return #"{"v":1,"ts":"\#(ts)","src":"claude","event":"\#(event)","session":"s","agent":"\#(agent)","project":"\#(project)","tool":null,"kind":\#(kindText),"note":null,"agents":[]}"# + "\n"
    }

    static func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}

final class CrewEventTailTests: XCTestCase {
    private var folder: URL!
    private var file: URL { folder.appendingPathComponent("events.jsonl") }

    override func setUpWithError() throws {
        folder = try CrewTestFiles.makeFolder()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testMissingFileGivesNothing() {
        XCTAssertEqual(CrewEventTail(url: file).poll(), [])
    }

    func testFirstOpenReadsExistingLinesAndThenOnlyNewOnes() throws {
        try CrewTestFiles.append(CrewTestFiles.line("prompt", second: 1), to: file)
        let tail = CrewEventTail(url: file)
        XCTAssertEqual(tail.poll().map(\.event), ["prompt"])
        XCTAssertEqual(tail.poll(), [])
        try CrewTestFiles.append(CrewTestFiles.line("turn.end", second: 2) + CrewTestFiles.line("prompt", second: 3), to: file)
        XCTAssertEqual(tail.poll().map(\.event), ["turn.end", "prompt"])
    }

    func testAppendAfterEmptyFirstPoll() throws {
        let tail = CrewEventTail(url: file)
        XCTAssertEqual(tail.poll(), [])
        try CrewTestFiles.append(CrewTestFiles.line("prompt"), to: file)
        XCTAssertEqual(tail.poll().count, 1)
    }

    func testPartialLineWaitsForItsNewline() throws {
        let full = CrewTestFiles.line("prompt", second: 4)
        let cut = full.index(full.startIndex, offsetBy: 40)
        let tail = CrewEventTail(url: file)
        try CrewTestFiles.append(CrewTestFiles.line("turn.end"), to: file)
        XCTAssertEqual(tail.poll().count, 1)
        try CrewTestFiles.append(String(full[..<cut]), to: file)
        XCTAssertEqual(tail.poll(), [])
        try CrewTestFiles.append(String(full[cut...]), to: file)
        let events = tail.poll()
        XCTAssertEqual(events.map(\.event), ["prompt"])
        XCTAssertEqual(events.first?.ts, crewDate("2026-11-27T14:00:04.000Z"))
    }

    func testBadLineIsSkipped() throws {
        let tail = CrewEventTail(url: file)
        try CrewTestFiles.append("garbage\n" + CrewTestFiles.line("prompt"), to: file)
        XCTAssertEqual(tail.poll().map(\.event), ["prompt"])
    }

    func testTruncateStartsAgainFromTheTop() throws {
        let tail = CrewEventTail(url: file)
        try CrewTestFiles.append(CrewTestFiles.line("prompt") + CrewTestFiles.line("prompt"), to: file)
        XCTAssertEqual(tail.poll().count, 2)
        // Same inode, smaller size.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.close()
        try CrewTestFiles.append(CrewTestFiles.line("turn.end"), to: file)
        XCTAssertEqual(tail.poll().map(\.event), ["turn.end"])
    }

    func testRotateReadsTheNewFileFromTheTop() throws {
        let tail = CrewEventTail(url: file)
        try CrewTestFiles.append(CrewTestFiles.line("prompt") + CrewTestFiles.line("prompt"), to: file)
        XCTAssertEqual(tail.poll().count, 2)
        // The writer renames the file and starts a new one. The new file may be larger
        // than the old offset, so only the inode tells the two apart.
        try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("events.jsonl.1"))
        try CrewTestFiles.append(
            CrewTestFiles.line("turn.end") + CrewTestFiles.line("turn.end") + CrewTestFiles.line("turn.end"), to: file)
        XCTAssertEqual(tail.poll().map(\.event), ["turn.end", "turn.end", "turn.end"])
    }

    func testFileThatVanishesAndReturnsIsReadFromTheTop() throws {
        let tail = CrewEventTail(url: file)
        try CrewTestFiles.append(CrewTestFiles.line("prompt"), to: file)
        XCTAssertEqual(tail.poll().count, 1)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(tail.poll(), [])
        try CrewTestFiles.append(CrewTestFiles.line("turn.end"), to: file)
        XCTAssertEqual(tail.poll().map(\.event), ["turn.end"])
    }

    func testFirstOpenOfALargeFileStartsNearTheEndAndDropsTheCutLine() throws {
        // About 320 KiB of lines. The first read starts 256 KiB from the end.
        let one = CrewTestFiles.line("prompt", agent: "old")
        let count = (320 * 1024) / one.utf8.count
        try CrewTestFiles.append(String(repeating: one, count: count) + CrewTestFiles.line("turn.end", agent: "new"), to: file)
        let events = CrewEventTail(url: file).poll()
        XCTAssertEqual(events.last?.agent, "new")
        XCTAssertLessThan(events.count, count)
        XCTAssertGreaterThan(events.count, count / 2)
        // The cut line is gone, so every line decoded.
        XCTAssertEqual(events.count, Int(256 * 1024 / one.utf8.count) + 1, accuracy: 3)
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, file: file, line: line)
}
