import XCTest

@testable import WhisperMaster

/// The native tool-call parser: Qwen3's `<tool_call>{name,arguments}</tool_call>`
/// into the same validated `AgentStep` the hand-rolled parser produces. Pure, so it
/// runs with no model — the reason this path is testable at all.
final class NativeToolCallParserTests: XCTestCase {
    private let tools = ToolCatalog.all

    private func toolsWithSlack() -> [ToolDescriptor] {
        // send_message needs its `connector` enum filled to validate, so build the
        // descriptor the registry would — a bare catalog entry has no allowed values.
        ToolCatalog.all.map { descriptor in
            guard descriptor.name == "send_message" else { return descriptor }
            return ToolDescriptor(
                name: descriptor.name, summary: descriptor.summary, access: descriptor.access,
                capability: descriptor.capability, targetArg: descriptor.targetArg,
                parameters: descriptor.parameters + [
                    ToolParameter("connector", description: "Which connector.",
                                  allowedValues: ["Work chat"])
                ])
        }
    }

    func testParsesANativeToolCall() {
        let raw = "<tool_call>\n{\"name\": \"list_calendar_events\", \"arguments\": {\"when\": \"tomorrow\"}}\n</tool_call>"
        guard case .success(.call(let call)) = NativeToolCallParser.parse(raw, tools: tools) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertEqual(call.tool, "list_calendar_events")
        XCTAssertEqual(call.arguments["when"], "tomorrow")
    }

    func testANoArgumentToolCallParses() {
        let raw = "<tool_call>\n{\"name\": \"list_tasks\", \"arguments\": {}}\n</tool_call>"
        guard case .success(.call(let call)) = NativeToolCallParser.parse(raw, tools: tools) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertEqual(call.tool, "list_tasks")
        XCTAssertTrue(call.arguments.isEmpty)
    }

    func testMissingArgumentsKeyIsTreatedAsNoArguments() {
        let raw = "<tool_call>\n{\"name\": \"list_tasks\"}\n</tool_call>"
        guard case .success(.call(let call)) = NativeToolCallParser.parse(raw, tools: tools) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertEqual(call.tool, "list_tasks")
    }

    func testPlainTextIsAnAnswer() {
        switch NativeToolCallParser.parse("You have two meetings today.", tools: tools) {
        case .success(.answer(let answer)):
            XCTAssertEqual(answer, "You have two meetings today.")
        default:
            XCTFail("expected an answer")
        }
    }

    func testEmptyOutputIsEmptyAnswer() {
        XCTAssertEqual(NativeToolCallParser.parse("   ", tools: tools), .failure(.emptyAnswer))
    }

    func testAnUnknownToolIsRejectedNotCoerced() {
        let raw = "<tool_call>\n{\"name\": \"delete_everything\", \"arguments\": {}}\n</tool_call>"
        XCTAssertEqual(NativeToolCallParser.parse(raw, tools: tools),
                       .failure(.unknownTool("delete_everything")))
    }

    /// Validation is delegated to `ToolCallParser`, so an invented connector fails the
    /// enum check exactly as on the hand-rolled path.
    func testAnInventedConnectorIsRejected() {
        let raw = "<tool_call>\n{\"name\": \"send_message\", \"arguments\": {\"channel\": \"#ops\", \"text\": \"hi\", \"connector\": \"Nope\"}}\n</tool_call>"
        XCTAssertEqual(NativeToolCallParser.parse(raw, tools: toolsWithSlack()),
                       .failure(.valueNotAllowed(argument: "connector", value: "Nope")))
    }

    /// A truncated generation — the opening tag but no closing one — still yields the
    /// call, because the JSON scan is balanced-brace, not tag-delimited.
    func testATruncatedToolCallStillParses() {
        let raw = "<tool_call>\n{\"name\": \"list_messages\", \"arguments\": {}}"
        guard case .success(.call(let call)) = NativeToolCallParser.parse(raw, tools: tools) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertEqual(call.tool, "list_messages")
    }

    /// Prose around the block is ignored — the first tool call wins.
    func testProseBeforeTheToolCallIsIgnored() {
        let raw = "Sure, let me check.\n<tool_call>\n{\"name\": \"list_mail\", \"arguments\": {}}\n</tool_call>"
        guard case .success(.call(let call)) = NativeToolCallParser.parse(raw, tools: tools) else {
            return XCTFail("expected a tool call")
        }
        XCTAssertEqual(call.tool, "list_mail")
    }
}
