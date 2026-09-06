import XCTest

@testable import WhisperMaster

/// What the notch says a tool wants to do, and how a model-authored choice is read.
final class AgentAskTests: XCTestCase {

    private func permissionEvent(
        tool: String?, input: String = "{}", requestID: String? = "r1",
        permTitle: String? = nil
    ) throws -> KunaiWire.Event {
        var json = #"{"seq":5,"t":"permission""#
        if let requestID { json += #","request_id":"\#(requestID)""# }
        if let tool { json += #","tool_name":"\#(tool)""# }
        if let permTitle { json += #","perm_title":"\#(permTitle)""# }
        json += #","input":\#(input)}"#
        return try JSONDecoder().decode(KunaiWire.Event.self, from: Data(json.utf8))
    }

    // MARK: Approval copy

    func testBashShowsTheCommandItWantsToRun() throws {
        let ask = AgentAsk.make(
            from: try permissionEvent(tool: "Bash", input: #"{"command":"rm -rf build/"}"#),
            sessionTitle: "whisper-master")
        guard case .approval(let approval) = ask else { return XCTFail("expected an approval") }
        XCTAssertEqual(approval.headline, "Run  rm -rf build/")
    }

    func testAPathIsShortenedFromTheInformativeEnd() {
        // The tail of a path is what identifies it, and a Swift project is full of
        // files that share a leaf name.
        XCTAssertEqual(
            AgentApproval.lastTwoComponents("/Users/x/repo/Sources/UI/Theme.swift"),
            "UI/Theme.swift")
        XCTAssertEqual(AgentApproval.lastTwoComponents("Theme.swift"), "Theme.swift")
    }

    func testAnUnrecognisedToolStillGetsAUsableLine() throws {
        // A tool added to Claude Code later must degrade to a plainer card, never an
        // empty one.
        let ask = AgentAsk.make(
            from: try permissionEvent(tool: "SomeNewTool", permTitle: "Do the new thing"),
            sessionTitle: "repo")
        guard case .approval(let approval) = ask else { return XCTFail("expected an approval") }
        XCTAssertEqual(approval.headline, "Do the new thing")
    }

    func testWithNoTitleAtAllTheToolNameIsBetterThanNothing() throws {
        let ask = AgentAsk.make(from: try permissionEvent(tool: "Mystery"), sessionTitle: "repo")
        guard case .approval(let approval) = ask else { return XCTFail("expected an approval") }
        XCTAssertEqual(approval.headline, "Mystery")
    }

    func testAnAskWithNoRequestIDIsRefused() throws {
        // There would be nothing to answer, and a card that cannot be answered holds
        // the turn open behind it.
        XCTAssertNil(
            AgentAsk.make(
                from: try permissionEvent(tool: "Bash", requestID: nil), sessionTitle: "r"))
    }

    // MARK: Choice

    func testAskUserQuestionBecomesAChoiceNotAnApproval() throws {
        let input = """
            {"questions":[{"question":"Which database?","header":"Database",
             "multiSelect":false,
             "options":[{"label":"Postgres"},{"label":"SQLite"}]}]}
            """
        let ask = AgentAsk.make(
            from: try permissionEvent(tool: "AskUserQuestion", input: input),
            sessionTitle: "repo")
        guard case .choice(let choice) = ask else { return XCTFail("expected a choice") }
        XCTAssertEqual(choice.primary?.text, "Which database?")
        XCTAssertEqual(choice.primary?.options, ["Postgres", "SQLite"])
        XCTAssertFalse(choice.primary?.multiSelect ?? true)
    }

    func testBareStringOptionsAreAcceptedToo() throws {
        let input = #"{"questions":[{"question":"Pick","options":["a","b"]}]}"#
        let ask = AgentAsk.make(
            from: try permissionEvent(tool: "AskUserQuestion", input: input),
            sessionTitle: "repo")
        guard case .choice(let choice) = ask else { return XCTFail("expected a choice") }
        XCTAssertEqual(choice.primary?.options, ["a", "b"])
    }

    func testAMalformedQuestionFallsBackToAnAnswerableApproval() throws {
        // The turn is suspended behind this. An unparseable question must still leave
        // the user something they can act on, or nothing ever resolves it.
        let ask = AgentAsk.make(
            from: try permissionEvent(tool: "AskUserQuestion", input: #"{"questions":[]}"#),
            sessionTitle: "repo")
        guard case .approval = ask else { return XCTFail("expected the approval fallback") }
    }

    func testMultiSelectIsCommaJoinedTheWayKunaiExpects() {
        let question = AgentChoice.Question(
            text: "Which platforms?", header: nil, multiSelect: true,
            options: ["macOS", "iOS", "web"])
        XCTAssertEqual(
            AgentChoice.answers(for: question, selected: ["macOS", "web"]),
            ["Which platforms?": "macOS,web"])
    }

    func testAnOptionTooLongToShowHonestlyDefersToKunai() {
        // Options are never truncated: shortening the text of something a person is
        // choosing between is the same failure as abbreviating a consent payload.
        let long = String(repeating: "x", count: 200)
        let choice = AgentChoice(
            requestID: "r",
            questions: [.init(text: "Q", header: nil, multiSelect: false, options: [long])],
            context: "repo")
        XCTAssertFalse(choice.isPresentable())
    }

    func testAChoiceWithNoOptionsIsNotPresentable() {
        let choice = AgentChoice(
            requestID: "r",
            questions: [.init(text: "Q", header: nil, multiSelect: false, options: [])],
            context: "repo")
        XCTAssertFalse(choice.isPresentable())
    }

    func testExtraOptionsAreCountedRatherThanDroppedSilently() {
        let question = AgentChoice.Question(
            text: "Q", header: nil, multiSelect: false,
            options: ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(question.visibleOptions.count, AgentChoice.maxVisibleOptions)
        XCTAssertEqual(question.hiddenOptionCount, 2)
    }
}
