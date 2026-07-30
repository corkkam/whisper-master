import XCTest

@testable import WhisperMaster

/// The parser is the guard between a 4-bit 3B model and real actions, so these tests
/// are mostly about what it **refuses**. Pure — no model, which matters because MLX
/// inference can't run under `swift test` at all.
final class ToolCallParserTests: XCTestCase {
    private let tools: [ToolDescriptor] = [
        ToolDescriptor(
            name: "list_calendar_events",
            summary: "List today's events.",
            access: .read, capability: .events, targetArg: nil,
            parameters: [
                ToolParameter("connector", isRequired: false,
                              description: "Which one.", allowedValues: ["Work", "Personal"]),
            ]),
        ToolDescriptor(
            name: "send_message",
            summary: "Post a message.",
            access: .write, capability: .messages, targetArg: "channel",
            parameters: [
                ToolParameter("channel", isRequired: true, description: "Channel."),
                ToolParameter("text", isRequired: true, description: "Body."),
                ToolParameter("limit", type: .integer, isRequired: false, description: "Count."),
                ToolParameter("silent", type: .boolean, isRequired: false, description: "Quiet."),
            ]),
    ]

    private func parse(_ raw: String) -> Result<AgentStep, ToolCallParseError> {
        ToolCallParser.parse(raw, tools: tools)
    }

    // MARK: - Happy paths

    func testParsesAToolCall() throws {
        let step = try parse(#"{"tool":"list_calendar_events","args":{"connector":"Work"}}"#).get()
        XCTAssertEqual(step, .call(ToolCall(tool: "list_calendar_events",
                                            arguments: ["connector": "Work"])))
    }

    func testParsesAnAnswer() throws {
        let step = try parse(#"{"answer":"You have three meetings."}"#).get()
        XCTAssertEqual(step, .answer("You have three meetings."))
    }

    func testAcceptsArgumentsUnderEitherKey() throws {
        let step = try parse(#"{"tool":"list_calendar_events","arguments":{}}"#).get()
        XCTAssertEqual(step, .call(ToolCall(tool: "list_calendar_events", arguments: [:])))
    }

    func testMissingArgsObjectIsTreatedAsNoArguments() throws {
        let step = try parse(#"{"tool":"list_calendar_events"}"#).get()
        XCTAssertEqual(step, .call(ToolCall(tool: "list_calendar_events", arguments: [:])))
    }

    /// An answer alongside a tool call means finished — one more call would be the model
    /// second-guessing a conclusion it already reached.
    func testAnswerWinsWhenBothKeysArePresent() throws {
        let step = try parse(#"{"answer":"Done.","tool":"list_calendar_events"}"#).get()
        XCTAssertEqual(step, .answer("Done."))
    }

    // MARK: - Extraction from messy output

    func testExtractsJSONFromSurroundingProse() throws {
        let raw = "Sure! Here's the call:\n```json\n{\"tool\":\"list_calendar_events\",\"args\":{}}\n```\nHope that helps."
        let step = try parse(raw).get()
        XCTAssertEqual(step, .call(ToolCall(tool: "list_calendar_events", arguments: [:])))
    }

    /// A brace inside a string mustn't end the scan — otherwise a message body
    /// containing `}` truncates the JSON and the call is silently lost.
    func testBraceInsideAStringDoesNotEndExtraction() throws {
        let raw = ##"{"tool":"send_message","args":{"channel":"#ops","text":"use {this} form"}}"##
        let step = try parse(raw).get()
        guard case .call(let call) = step else { return XCTFail("expected a call") }
        XCTAssertEqual(call.arguments["text"], "use {this} form")
    }

    func testEscapedQuoteDoesNotConfuseExtraction() throws {
        let raw = ##"{"tool":"send_message","args":{"channel":"#ops","text":"say \"hi\""}}"##
        let step = try parse(raw).get()
        guard case .call(let call) = step else { return XCTFail("expected a call") }
        XCTAssertEqual(call.arguments["text"], #"say "hi""#)
    }

    func testTruncatedGenerationIsRejectedNotSalvaged() {
        XCTAssertEqual(parse(##"{"tool":"send_message","args":{"channel":"#ops""##),
                       .failure(.noJSONFound))
    }

    func testNoJSONAtAll() {
        XCTAssertEqual(parse("I think you have three meetings today."), .failure(.noJSONFound))
        XCTAssertEqual(parse(""), .failure(.noJSONFound))
    }

    func testMalformedJSON() {
        XCTAssertEqual(parse("{not json at all}"), .failure(.malformedJSON))
    }

    // MARK: - Rejection, not coercion

    func testUnknownToolIsRejected() {
        XCTAssertEqual(parse(#"{"tool":"delete_everything","args":{}}"#),
                       .failure(.unknownTool("delete_everything")))
    }

    func testUnknownArgumentIsRejected() {
        XCTAssertEqual(parse(#"{"tool":"list_calendar_events","args":{"bogus":"x"}}"#),
                       .failure(.unknownArgument(tool: "list_calendar_events", argument: "bogus")))
    }

    func testMissingRequiredArgumentIsRejected() {
        XCTAssertEqual(parse(##"{"tool":"send_message","args":{"channel":"#ops"}}"##),
                       .failure(.missingRequiredArgument(tool: "send_message", argument: "text")))
    }

    /// The whole point of enumerating allowed values: an invented connector name fails
    /// before any provider is touched.
    func testInventedConnectorNameIsRejected() {
        XCTAssertEqual(parse(#"{"tool":"list_calendar_events","args":{"connector":"Holiday"}}"#),
                       .failure(.valueNotAllowed(argument: "connector", value: "Holiday")))
    }

    /// The model echoes a label the user spoke, so case shouldn't matter — but the
    /// *canonical* label is what gets stored, so downstream matching is exact.
    func testAllowedValueMatchIsCaseInsensitiveAndCanonicalised() throws {
        let step = try parse(#"{"tool":"list_calendar_events","args":{"connector":"work"}}"#).get()
        guard case .call(let call) = step else { return XCTFail("expected a call") }
        XCTAssertEqual(call.arguments["connector"], "Work")
    }

    /// `"limit":"lots"` must not become a silent zero.
    func testStringForAnIntegerArgumentIsRejected() {
        XCTAssertEqual(parse(##"{"tool":"send_message","args":{"channel":"#a","text":"b","limit":"lots"}}"##),
                       .failure(.wrongType(argument: "limit", expected: "integer")))
    }

    func testFractionalNumberForAnIntegerArgumentIsRejected() {
        XCTAssertEqual(parse(##"{"tool":"send_message","args":{"channel":"#a","text":"b","limit":2.5}}"##),
                       .failure(.wrongType(argument: "limit", expected: "integer")))
    }

    func testStringForABooleanArgumentIsRejected() {
        XCTAssertEqual(parse(##"{"tool":"send_message","args":{"channel":"#a","text":"b","silent":"yes"}}"##),
                       .failure(.wrongType(argument: "silent", expected: "boolean")))
    }

    /// A number where a string is expected is unambiguous, so it converts — channel ids
    /// and ticket numbers legitimately arrive as numbers.
    func testNumberForAStringArgumentIsAccepted() throws {
        let step = try parse(#"{"tool":"send_message","args":{"channel":12345,"text":"hi"}}"#).get()
        guard case .call(let call) = step else { return XCTFail("expected a call") }
        XCTAssertEqual(call.arguments["channel"], "12345")
    }

    /// An explicit null is "not supplied", not the string "null".
    func testExplicitNullIsTreatedAsAbsent() {
        XCTAssertEqual(parse(##"{"tool":"send_message","args":{"channel":"#a","text":null}}"##),
                       .failure(.missingRequiredArgument(tool: "send_message", argument: "text")))
    }

    func testEmptyStringForARequiredArgumentIsRejected() {
        XCTAssertEqual(parse(##"{"tool":"send_message","args":{"channel":"#a","text":""}}"##),
                       .failure(.missingRequiredArgument(tool: "send_message", argument: "text")))
    }

    func testEmptyAnswerIsRejected() {
        XCTAssertEqual(parse(#"{"answer":"   "}"#), .failure(.emptyAnswer))
    }

    func testMissingToolName() {
        XCTAssertEqual(parse(#"{"args":{}}"#), .failure(.missingToolName))
    }

    // MARK: - Feedback

    /// Every rejection must give the model something actionable, or it repeats the same
    /// malformed call until the budget runs out.
    func testEveryErrorProducesNonEmptyFeedback() {
        let errors: [ToolCallParseError] = [
            .noJSONFound, .malformedJSON, .missingToolName, .unknownTool("x"),
            .unknownArgument(tool: "t", argument: "a"),
            .missingRequiredArgument(tool: "t", argument: "a"),
            .wrongType(argument: "a", expected: "integer"),
            .valueNotAllowed(argument: "a", value: "v"), .emptyAnswer,
        ]
        for error in errors {
            XCTAssertFalse(error.modelFeedback.isEmpty, "\(error) has no feedback")
        }
    }

    // MARK: - Target extraction

    func testTargetComesFromTheDeclaredTargetArgument() throws {
        let step = try parse(##"{"tool":"send_message","args":{"channel":"#ops","text":"hi"}}"##).get()
        guard case .call(let call) = step else { return XCTFail("expected a call") }
        let descriptor = tools[1]
        XCTAssertEqual(call.target(for: descriptor), "#ops")
        XCTAssertNil(call.target(for: tools[0]), "a read tool has no target")
    }
}
