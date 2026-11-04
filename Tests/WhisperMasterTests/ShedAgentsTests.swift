import XCTest

@testable import WhisperMaster

/// Shed in the notch: session mapping, the event reader, asks, and the 409 retry.
/// No Shed server is involved; `FakeShed` stands in for the REST client.
final class ShedAgentsTests: XCTestCase {

    private func wire(_ json: String) throws -> ShedWire.Session {
        try JSONDecoder().decode(ShedWire.Session.self, from: Data(json.utf8))
    }

    // MARK: Mapping

    func testLiveStatesMapToSessionStates() throws {
        let cases: [(String, KunaiWire.SessionState)] = [
            ("working", .running), ("asking", .awaitingPermission), ("open", .idle),
        ]
        for (live, expected) in cases {
            let s = try wire(#"{"id":"claude:1","harness":"claude","liveState":"\#(live)","cwd":"/a/repo"}"#)
            XCTAssertEqual(AgentSession(shed: s)?.state, expected, live)
        }
    }

    func testHistoryHasNoRow() throws {
        XCTAssertNil(AgentSession(shed: try wire(#"{"id":"x","liveState":"history"}"#)))
    }

    func testHarnessAndAgentName() throws {
        let s = try wire(#"{"id":"codex:2","harness":"codex","liveState":"working","cwd":"/a/repo","agent":{"id":"a","name":"Reviewer","enabled":true},"account":"codex:work"}"#)
        let row = try XCTUnwrap(AgentSession(shed: s))
        XCTAssertEqual(row.harness, .codex)
        XCTAssertEqual(row.displayName, "Reviewer")
        XCTAssertEqual(try XCTUnwrap(AgentSession(shed: try wire(#"{"id":"g","harness":"gemini","liveState":"open","cwd":"/a/proj"}"#))).harness, .other)
        XCTAssertEqual(AgentSession(id: "i", repo: "proj").displayName, "proj")
    }

    // MARK: Event reader

    func testParserReadsFramesAndSkipsComments() {
        var parser = ShedEventParser()
        let lines = ["retry: 3000", "", ": still here", "", "event: status",
                     #"data: [{"id":"claude:1","liveState":"asking"}]"#, "",
                     "event: sessions", "data: {}", ""]
        let events = lines.compactMap { parser.feed($0) }
        XCTAssertEqual(events.map(\.name), ["status", "sessions"])
        XCTAssertEqual(events[0].statusChanges, [.init(id: "claude:1", liveState: "asking")])
        XCTAssertNil(events[1].statusChanges)
    }

    func testSplitterKeepsBlankLines() {
        var splitter = ShedLineSplitter()
        let lines = Array("event: a\r\n\r\n".utf8).compactMap { splitter.feed($0) }
        XCTAssertEqual(lines, ["event: a\r", "\r"])
        var parser = ShedEventParser()
        XCTAssertNil(parser.feed("data: 1"))
        XCTAssertEqual(parser.feed("\r")?.data, "1")
    }

    // MARK: Asks

    func testMenuBecomesAChoiceAsk() throws {
        let terminal = ShedWire.Terminal(
            tty: "t", text: "Edit file\n Do you want to make this edit?\n 1. Yes\n 2. No",
            menu: .init(options: ["Yes", "No"], current: 0))
        guard case .choice(let choice)? = ShedAsk.make(sessionID: "claude:1", context: "repo", terminal: terminal)
        else { return XCTFail("expected a choice") }
        XCTAssertEqual(choice.requestID, "claude:1")
        XCTAssertEqual(choice.primary?.text, "Do you want to make this edit?")
        XCTAssertEqual(choice.primary?.options, ["Yes", "No"])
        XCTAssertTrue(choice.isPresentable())
        XCTAssertNil(ShedAsk.make(sessionID: "s", context: "", terminal: .init(tty: nil, text: "x", menu: nil)))
    }

    // MARK: The 409 retry

    @MainActor
    func testChoiceSendsIndexAndLabelThenClears() async throws {
        let fake = FakeShed()
        fake.terminals = [menu(["Yes", "No"])]
        let shed = ShedAgents(makeClient: { _ in fake })
        await shed.refresh()
        guard case .choice(let choice)? = shed.ask else { return XCTFail("no ask") }
        await shed.answer(choice, selected: ["No"])
        XCTAssertEqual(fake.chosen.count, 1)
        XCTAssertEqual(fake.chosen[0].index, 1)
        XCTAssertEqual(fake.chosen[0].label, "No")
    }

    @MainActor
    func testA409ReadsTheMenuAgainAndShowsItAgain() async throws {
        let fake = FakeShed()
        fake.terminals = [menu(["Yes", "No"]), menu(["Allow once", "Allow always", "Deny"])]
        fake.results = [.changed]
        let shed = ShedAgents(makeClient: { _ in fake })
        await shed.refresh()
        guard case .choice(let first)? = shed.ask else { return XCTFail("no ask") }
        await shed.answer(first, selected: ["Yes"])
        guard case .choice(let second)? = shed.ask else { return XCTFail("ask was dropped") }
        XCTAssertEqual(second.primary?.options, ["Allow once", "Allow always", "Deny"])
    }

    @MainActor
    func testLongQuestionWithSixOptionsIsAnswerableInFull() async throws {
        let long = String(repeating: "Which approach should I take for this very long question? ", count: 4)
        let options = (1...6).map { "Option \($0) " + String(repeating: "x", count: 90) }
        let fake = FakeShed()
        fake.terminals = [.init(tty: "t", text: long, menu: .init(options: options, current: 0))]
        let shed = ShedAgents(makeClient: { _ in fake })
        await shed.refresh()
        guard case .choice(let choice)? = shed.ask else { return XCTFail("no ask") }
        XCTAssertTrue(choice.isShed)
        XCTAssertEqual(choice.primary?.options.count, 6)
        XCTAssertGreaterThan(choice.primary?.text.count ?? 0, 72)
        XCTAssertEqual(
            NotchAgentPanel.thickness(for: .choice(choice), otherSessions: 0, banner: 50),
            NotchShedChoiceCard.Metrics.height)
        await shed.answer(choice, selected: [options[5]])
        XCTAssertEqual(fake.chosen[0].index, 5)
        XCTAssertEqual(fake.chosen[0].label, options[5])
    }

    @MainActor
    func testSkipSendsNothingAndStaysSkipped() async throws {
        let fake = FakeShed()
        fake.terminals = [menu(["Yes", "No"])]
        let shed = ShedAgents(makeClient: { _ in fake })
        await shed.refresh()
        guard case .choice(let choice)? = shed.ask else { return XCTFail("no ask") }
        await shed.answer(choice, selected: [])
        XCTAssertTrue(fake.chosen.isEmpty)
        XCTAssertNil(shed.ask)
        await shed.refresh()
        XCTAssertNil(shed.ask)
    }

    // MARK: Endpoints and the link

    func testDiscoveryOrderAndInjectableToken() {
        let home = URL(fileURLWithPath: "/h")
        let found = ShedEndpoint.candidates(override: "", env: ["SHED_URL": "http://127.0.0.1:9000"], home: home)
        XCTAssertEqual(found.map(\.baseURL.absoluteString),
                       ["http://127.0.0.1:9000", "http://127.0.0.1:4378", "http://127.0.0.1:4379"])
        XCTAssertEqual(found[1].tokenFile.path, "/h/.shed/app/.laya-token")
        XCTAssertEqual(found[2].tokenFile.path, "/h/code/shed/.laya-token")
        let injected = ShedEndpoint(baseURL: URL(string: "http://127.0.0.1:1")!, tokenFile: URL(fileURLWithPath: "/t"))
        XCTAssertEqual(injected.tokenFile.path, "/t")
    }

    func testEndpointURLsAndToken() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "secret\n".write(to: tmp, atomically: true, encoding: .utf8)
        let e = ShedEndpoint(baseURL: URL(string: "http://127.0.0.1:4378")!, tokenFile: tmp)
        XCTAssertEqual(e.port, 4378)
        XCTAssertEqual(e.readToken(), "secret")
        XCTAssertEqual(e.pageURL().absoluteString, "http://127.0.0.1:4378/")
        XCTAssertEqual(e.pageURL(sessionID: "a b&c").absoluteString, "http://127.0.0.1:4378/?session=a%20b%26c")
    }

    @MainActor
    func testOpenSessionGoesThroughShedLink() {
        let endpoint = ShedEndpoint.local(port: 4378, root: URL(fileURLWithPath: "/r"))
        var opened: (String, ShedEndpoint?)?
        let previous = ShedLink.open
        ShedLink.open = { opened = ($0, $1) }
        defer { ShedLink.open = previous }
        ShedLink.openSession(id: "claude:1", endpoint: endpoint)
        XCTAssertEqual(opened?.0, "claude:1")
        XCTAssertEqual(opened?.1, endpoint)
    }

    private func menu(_ options: [String]) -> ShedWire.Terminal {
        .init(tty: "t", text: "Proceed?", menu: .init(options: options, current: 0))
    }
}

private final class FakeShed: ShedAPI, @unchecked Sendable {
    var terminals: [ShedWire.Terminal] = []
    var results: [ShedChoiceResult] = []
    var chosen: [(index: Int, label: String)] = []
    var isReachable: Bool { true }
    var activeEndpoint: ShedEndpoint? { nil }

    func agentSessions() async -> [AgentSession] {
        [AgentSession(id: "claude:1", repo: "repo", state: .awaitingPermission)]
    }
    func terminal(sessionID: String) async -> ShedWire.Terminal? {
        terminals.isEmpty ? nil : terminals.removeFirst()
    }
    func choose(sessionID: String, index: Int, label: String) async -> ShedChoiceResult {
        chosen.append((index, label))
        return results.isEmpty ? .chosen : results.removeFirst()
    }
    func interrupt(sessionID: String) async -> Bool { true }
    func phoneAccess() async -> ShedWire.PhoneAccess? { nil }
    func useTailscale() async -> ShedPhoneResult { .failed("n/a") }
    func accounts() async -> [ShedWire.Account]? { nil }
    func events() -> AsyncStream<ShedEvent> { AsyncStream { $0.finish() } }
}
