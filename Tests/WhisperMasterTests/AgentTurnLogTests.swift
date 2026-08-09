import XCTest

@testable import WhisperMaster

/// The readable tail of a session, folded from wire events.
final class AgentTurnLogTests: XCTestCase {

    private func decode(_ json: String) throws -> KunaiWire.Event {
        try JSONDecoder().decode(KunaiWire.Event.self, from: Data(json.utf8))
    }

    func testDeltasStreamAndAreReplacedByTheFinishedMessage() throws {
        // kunai streams text as `delta` and then sends the whole message as
        // `assistant`. Committing the deltas as well would show the reply twice.
        var log = AgentTurnLog()
        try log.apply(decode(#"{"seq":1,"t":"delta","text":"Clearing "}"#))
        try log.apply(decode(#"{"seq":2,"t":"delta","text":"the build"}"#))
        XCTAssertEqual(log.renderable.count, 1)

        try log.apply(
            decode(
                #"{"seq":3,"t":"assistant","blocks":[{"type":"text","text":"Clearing the build."}]}"#
            ))
        XCTAssertEqual(log.renderable.count, 1)
        guard case .assistant(_, let text) = log.renderable[0] else {
            return XCTFail("expected an assistant line")
        }
        XCTAssertEqual(text, "Clearing the build.")
    }

    func testAToolCallIsAnnouncedOnceAndThenGetsItsVerdict() throws {
        // The `tool_use` block arrives first, then the permission ask fills in the
        // detail, then the result lands. All three describe one call.
        var log = AgentTurnLog()
        try log.apply(
            decode(
                #"{"seq":1,"t":"assistant","blocks":[{"type":"tool_use","id":"t1","name":"Bash"}]}"#
            ))
        try log.apply(
            decode(
                #"{"seq":2,"t":"permission","request_id":"r1","tool_use_id":"t1","tool_name":"Bash","input":{"command":"swift test"}}"#
            ))
        try log.apply(decode(#"{"seq":3,"t":"tool_result","tool_use_id":"t1"}"#))

        let tools = log.entries.filter { if case .tool = $0 { return true } else { return false } }
        XCTAssertEqual(tools.count, 1, "one call must not render as three rows")
        guard case .tool(_, let name, let detail, let verdict) = tools[0] else {
            return XCTFail("expected a tool line")
        }
        XCTAssertEqual(name, "Bash")
        XCTAssertEqual(detail, "Run  swift test")
        XCTAssertEqual(verdict, "done")
    }

    func testAFailedToolSaysSo() throws {
        var log = AgentTurnLog()
        try log.apply(
            decode(
                #"{"seq":1,"t":"assistant","blocks":[{"type":"tool_use","id":"t1","name":"Bash"}]}"#
            ))
        try log.apply(decode(#"{"seq":2,"t":"tool_result","tool_use_id":"t1","is_error":true}"#))
        guard case .tool(_, _, _, let verdict) = log.entries[0] else {
            return XCTFail("expected a tool line")
        }
        XCTAssertEqual(verdict, "failed")
    }

    func testThinkingBlocksStayOutOfTheTail() throws {
        var log = AgentTurnLog()
        try log.apply(
            decode(
                #"{"seq":1,"t":"assistant","blocks":[{"type":"thinking","text":"hmm"},{"type":"text","text":"Done."}]}"#
            ))
        XCTAssertEqual(log.entries.count, 1)
    }

    func testTheTailIsBoundedSoALongSessionCannotGrowTheBand() throws {
        var log = AgentTurnLog()
        for seq in 1...20 {
            try log.apply(decode(#"{"seq":\#(seq),"t":"user","text":"line \#(seq)"}"#))
        }
        XCTAssertEqual(log.entries.count, AgentTurnLog.maxEntries)
        guard case .user(_, let text) = log.entries.last else { return XCTFail("expected a user line") }
        XCTAssertEqual(text, "line 20", "the tail must keep the newest, not the oldest")
    }

    func testResetClearsEverythingIncludingTheResumeMark() throws {
        // What a respawn requires: the replacement process numbers from 1 again, so a
        // retained high-water mark would swallow the whole new conversation.
        var log = AgentTurnLog()
        try log.apply(decode(#"{"seq":9,"t":"user","text":"hi"}"#))
        XCTAssertEqual(log.highestSeq, 9)
        log.reset()
        XCTAssertEqual(log.highestSeq, 0)
        XCTAssertTrue(log.isEmpty)
    }

    func testWhitespaceOnlyTextNeverBecomesAnEmptyLine() throws {
        var log = AgentTurnLog()
        try log.apply(decode(#"{"seq":1,"t":"user","text":"   \n "}"#))
        XCTAssertTrue(log.isEmpty)
    }

    // MARK: Change set

    func testOnlyWritingToolsCountAsChanges() throws {
        // A Read is not a change. Counting one would make every turn look destructive.
        var log = AgentTurnLog()
        try log.apply(
            decode(
                #"{"seq":1,"t":"permission","request_id":"r1","tool_use_id":"t1","tool_name":"Read","input":{"file_path":"/a/b/Read.swift"}}"#
            ))
        try log.apply(
            decode(
                #"{"seq":2,"t":"permission","request_id":"r2","tool_use_id":"t2","tool_name":"Edit","input":{"file_path":"/a/b/Edited.swift"}}"#
            ))
        XCTAssertEqual(AgentChangeSet.editedPaths(in: log), ["b/Edited.swift"])
    }

    func testTheUndoSummaryLeadsWithTheIrreversibleHalf() {
        // Restoring a tracked file is recoverable; deleting an untracked one is not,
        // so the deletion must not be the clause someone stops reading before.
        let preview = AgentChangeSet.RevertPreview(
            changed: ["a.swift", "b.swift"], removed: ["scratch.txt"])
        XCTAssertEqual(preview.summary, "1 untracked file deleted, 2 files restored")
    }

    func testWithNothingToDeleteTheSummaryStaysShort() {
        let preview = AgentChangeSet.RevertPreview(changed: ["a.swift"], removed: [])
        XCTAssertEqual(preview.summary, "1 file restored")
    }
}
