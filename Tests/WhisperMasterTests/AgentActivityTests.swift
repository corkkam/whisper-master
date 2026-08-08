import XCTest

@testable import WhisperMaster

/// The band's live caption while the assistant works. Before this the notch said
/// "Working on it" for the whole run — up to `AgentLoop.budget` (30s) across as many
/// as `maxIterations` tool calls — so a calendar read, a Slack post and a stuck
/// connector were all the same sentence.
final class AgentActivityTests: XCTestCase {
    private func call(_ tool: String, _ arguments: [String: String] = [:]) -> ToolCall {
        ToolCall(tool: tool, arguments: arguments)
    }

    // MARK: - Naming the connector

    func testAScopedCalendarReadNamesTheConnection() {
        XCTAssertEqual(
            AgentActivity.running(call("list_calendar_events",
                                       [ToolDescriptor.instanceArgument: "Personal"])).caption,
            "Checking Personal")
    }

    /// An unqualified read merges every connector of that kind, so naming one would
    /// be a lie and naming none would be silent.
    func testAnUnqualifiedReadSaysItIsCheckingAllOfThem() {
        XCTAssertEqual(
            AgentActivity.running(call("list_calendar_events")).caption,
            "Checking your calendars")
    }

    func testACalendarWriteNamesTheConnectionItWillWriteTo() {
        XCTAssertEqual(
            AgentActivity.running(call("create_calendar_event",
                                       ["title": "Work",
                                        ToolDescriptor.instanceArgument: "Personal"])).caption,
            "Adding to Personal")
    }

    /// `send_message` declares `channel` as its target, so that — not the account —
    /// is what the caption should name: "Posting to Work" would not tell the user
    /// which channel is about to receive their words.
    func testAMessageWriteNamesTheChannelRatherThanTheAccount() {
        XCTAssertEqual(
            AgentActivity.running(call("send_message",
                                       ["channel": "#ops", "text": "hi",
                                        ToolDescriptor.instanceArgument: "Work"])).caption,
            "Posting to #ops")
    }

    /// Local tools act on this Mac, so there's no connection to name.
    func testLocalToolsNameTheirOwnAction() {
        XCTAssertEqual(AgentActivity.running(call("create_note", ["body": "x"])).caption,
                       "Saving a note")
        XCTAssertEqual(AgentActivity.running(call("create_reminder", ["title": "x"])).caption,
                       "Setting a reminder")
        XCTAssertEqual(AgentActivity.running(call("list_reminders")).caption,
                       "Checking reminders")
    }

    // MARK: - What it must never say

    /// The notch showing `list_calendar_events` is the same class of leak the
    /// approval card's raw arguments were. An unrecognised tool falls back to the
    /// generic line rather than printing its identifier.
    func testAnUnknownToolNeverLeaksItsNameToTheNotch() {
        let caption = AgentActivity.running(call("archive_thread", ["thread": "42"])).caption
        XCTAssertEqual(caption, AgentActivity.generic)
        XCTAssertFalse(caption.contains("archive_thread"))
    }

    /// A blank connector argument is the same as none — an empty string would render
    /// "Checking " with a dangling space.
    func testABlankTargetIsTreatedAsUnqualified() {
        XCTAssertEqual(
            AgentActivity.running(call("list_calendar_events",
                                       [ToolDescriptor.instanceArgument: "  "])).caption,
            "Checking your calendars")
    }

    func testThinkingIsTheGenericLine() {
        XCTAssertEqual(AgentActivity.thinking.caption, "Working on it")
    }

    // MARK: - Where it reaches the band

    /// The caption only ever replaces the assistant's own "Working on it". A step
    /// left set in any other state must not re-caption an ordinary dictation.
    @MainActor
    func testTheCaptionOnlyReplacesTheAssistantsWorkingLine() {
        let step = AgentActivity.running(tool: "list_calendar_events", target: "Personal")
        XCTAssertEqual(
            NotchActivity.polishing.label(holdToTalk: true, commandCapture: true, agentActivity: step),
            "Checking Personal")
        XCTAssertEqual(
            NotchActivity.polishing.label(holdToTalk: true, commandCapture: false, agentActivity: step),
            "Polishing")
        XCTAssertEqual(
            NotchActivity.listening.label(holdToTalk: true, commandCapture: false, agentActivity: step),
            "Dictating")
    }

    /// No step yet (the model is loading, or the loop hasn't reported) still has to
    /// say something.
    @MainActor
    func testTheAssistantLineFallsBackWhenThereIsNoStep() {
        XCTAssertEqual(
            NotchActivity.polishing.label(holdToTalk: true, commandCapture: true, agentActivity: nil),
            "Working on it")
    }
}
