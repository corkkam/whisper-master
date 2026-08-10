import XCTest

@testable import WhisperMaster

/// The finish banner holds one line, and Claude writes markdown. These pin the
/// presentation that turned a reply opening with a code fence into a title of
/// literally ``` on the band.
final class AgentReplyLineTests: XCTestCase {

    func testAReplyOpeningWithACodeFenceShowsItsProseNotTheFence() {
        let raw = """
            ```swift
            let x = 1
            ```
            Cleared the build and rewrote the assertion.
            """
        XCTAssertEqual(
            AgentReplyLine.compact(raw), "Cleared the build and rewrote the assertion.")
    }

    func testPlainProseIsUntouched() {
        XCTAssertEqual(AgentReplyLine.compact("Done. All tests pass."), "Done. All tests pass.")
    }

    func testMarkdownChromeIsStrippedButTheWordsAreNot() {
        XCTAssertEqual(AgentReplyLine.compact("## Fixed the `route` bug"), "Fixed the route bug")
        XCTAssertEqual(AgentReplyLine.compact("- **First**: renamed it"), "First: renamed it")
    }

    func testAReplyThatIsOnlyCodeYieldsNilSoTheCallerSaysFinished() {
        let raw = """
            ```
            swift build
            ```
            """
        XCTAssertNil(AgentReplyLine.compact(raw))
    }

    func testLeadingBlankLinesAreSkipped() {
        XCTAssertEqual(AgentReplyLine.compact("\n\n  \nShipped it."), "Shipped it.")
    }

    // MARK: The working caption

    func testTheWorkingCaptionNamesTheToolCallInProgress() throws {
        var log = AgentTurnLog()
        try log.apply(decode(
            #"{"seq":1,"t":"assistant","blocks":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/x/UI/NotchGlow.swift"}}]}"#))
        XCTAssertEqual(log.currentActivity, "Editing UI/NotchGlow.swift")
    }

    func testAFinishedCallStillBeatsABareRepoName() throws {
        var log = AgentTurnLog()
        try log.apply(decode(
            #"{"seq":1,"t":"assistant","blocks":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}"#))
        try log.apply(decode(#"{"seq":2,"t":"tool_result","tool_use_id":"t1"}"#))
        XCTAssertEqual(log.currentActivity, "Running swift test")
    }

    func testTheInFlightCallOutranksTheFinishedOne() throws {
        var log = AgentTurnLog()
        try log.apply(decode(
            #"{"seq":1,"t":"assistant","blocks":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"old"}}]}"#))
        try log.apply(decode(#"{"seq":2,"t":"tool_result","tool_use_id":"t1"}"#))
        try log.apply(decode(
            #"{"seq":3,"t":"assistant","blocks":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/x/a/b.swift"}}]}"#))
        XCTAssertEqual(log.currentActivity, "Reading a/b.swift")
    }

    func testNoToolsYetMeansNoActivitySoTheRowShowsTheRepo() {
        XCTAssertNil(AgentTurnLog().currentActivity)
    }

    private func decode(_ json: String) throws -> KunaiWire.Event {
        try JSONDecoder().decode(KunaiWire.Event.self, from: Data(json.utf8))
    }
}
