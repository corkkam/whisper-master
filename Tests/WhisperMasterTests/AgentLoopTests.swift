import XCTest

@testable import WhisperMaster

/// The loop's control flow, driven by a scripted generator.
///
/// The generator is injected precisely so this is testable: MLX inference cannot run
/// under `swift test` at all (Metal shaders only compile under xcodebuild), so a loop
/// that owned a real model would have zero test coverage for its iteration cap, its
/// retry feedback, or its fallback — the parts most likely to misbehave against a 3B.
@MainActor
final class AgentLoopTests: XCTestCase {
    private func makeStore() -> ConnectorInstanceStore {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        store.add(ConnectorInstance(
            kind: .googleCalendar, label: "Work", identity: "sam@acme.com",
            config: .calendars(identifiers: ["cal-1"], sourceTitle: "Google")))
        return store
    }

    /// Returns the scripted replies in order, then nil (a dead model).
    private func scripted(_ replies: [String]) -> (AgentLoop.Generate, () -> Int) {
        var index = 0
        let generate: AgentLoop.Generate = { _, _ in
            defer { index += 1 }
            return index < replies.count ? replies[index] : nil
        }
        return (generate, { index })
    }

    private func makeLoop(store: ConnectorInstanceStore,
                          generate: @escaping AgentLoop.Generate,
                          maxIterations: Int = 4) -> AgentLoop {
        let router = ToolRouter(store: store, requestApproval: { _ in .denied })
        let tools = ToolRegistry.available(store: store)
        return AgentLoop(tools: tools, router: router, generate: generate,
                         maxIterations: maxIterations)
    }

    // MARK: - Happy paths

    func testAnswersImmediately() async {
        let store = makeStore()
        let (generate, calls) = scripted([#"{"answer":"You have two meetings."}"#])
        let outcome = await makeLoop(store: store, generate: generate).run(question: "what's my day")

        XCTAssertFalse(outcome.exhausted)
        XCTAssertEqual(outcome.answer, "You have two meetings.")
        XCTAssertEqual(calls(), 1, "an immediate answer costs exactly one generation")
    }

    func testCallsAToolThenAnswers() async {
        let store = makeStore()
        let (generate, calls) = scripted([
            #"{"tool":"list_connectors","args":{}}"#,
            #"{"answer":"You have one calendar, Work."}"#,
        ])
        let outcome = await makeLoop(store: store, generate: generate).run(question: "what's connected")

        XCTAssertFalse(outcome.exhausted)
        XCTAssertEqual(outcome.answer, "You have one calendar, Work.")
        XCTAssertEqual(calls(), 2)
        // model → tool → model
        XCTAssertEqual(outcome.turns.map(\.role), [.model, .tool, .model])
        XCTAssertTrue(outcome.turns[1].text.contains("Work"),
                      "the tool result must carry the connector's name")
    }

    // MARK: - Progress reporting

    /// The notch's caption comes from these. Two rules matter: a step is reported
    /// **before** the call, not after — reporting on completion would caption a
    /// connector the loop has already finished waiting on, which is the exact
    /// opposite of what a slow connector needs — and each call gets its own, so a
    /// run spanning two connections names both in turn.
    func testEachToolCallIsReportedBeforeItRuns() async {
        let store = makeStore()
        let (generate, _) = scripted([
            #"{"tool":"list_connectors","args":{}}"#,
            #"{"tool":"list_calendar_events","args":{"connector":"Work"}}"#,
            #"{"answer":"Two meetings on Work."}"#,
        ])
        var loop = makeLoop(store: store, generate: generate)
        var steps: [AgentActivity] = []
        loop.onStep = { steps.append($0) }

        _ = await loop.run(question: "what's my day")

        XCTAssertEqual(steps, [
            .thinking,
            .running(tool: "list_connectors", target: nil),
            .running(tool: "list_calendar_events", target: "Work"),
        ])
    }

    /// `.thinking` is reported once, not before every generation. After a call
    /// returns, the model is reasoning about *that connector's* result, so holding
    /// its caption is both truthful and calmer than flipping back to the generic
    /// line between every step.
    func testTheGenericLineIsReportedOnceRatherThanBetweenEveryStep() async {
        let store = makeStore()
        let (generate, _) = scripted([
            #"{"tool":"list_connectors","args":{}}"#,
            #"{"answer":"One calendar."}"#,
        ])
        var loop = makeLoop(store: store, generate: generate)
        var steps: [AgentActivity] = []
        loop.onStep = { steps.append($0) }

        _ = await loop.run(question: "what's connected")

        XCTAssertEqual(steps.filter { $0 == .thinking }.count, 1)
    }

    /// A repeat the loop refuses never reached a connector, so captioning it would
    /// name work that isn't happening.
    func testARefusedRepeatIsNotReported() async {
        let store = makeStore()
        let (generate, _) = scripted([
            #"{"tool":"list_connectors","args":{}}"#,
            #"{"tool":"list_connectors","args":{}}"#,
            #"{"answer":"One calendar."}"#,
        ])
        var loop = makeLoop(store: store, generate: generate)
        var steps: [AgentActivity] = []
        loop.onStep = { steps.append($0) }

        _ = await loop.run(question: "what's connected")

        XCTAssertEqual(steps.filter { $0 != .thinking }.count, 1,
                       "the second identical call is refused, so it isn't announced")
    }

    // MARK: - Recovery

    /// A malformed call costs one iteration and gets specific feedback, rather than
    /// being coerced into something plausible.
    func testRecoversFromAMalformedCall() async {
        let store = makeStore()
        let (generate, calls) = scripted([
            "I'll check your calendar for you!",
            #"{"answer":"Two meetings today."}"#,
        ])
        let outcome = await makeLoop(store: store, generate: generate).run(question: "what's my day")

        XCTAssertFalse(outcome.exhausted)
        XCTAssertEqual(outcome.answer, "Two meetings today.")
        XCTAssertEqual(calls(), 2)
        XCTAssertTrue(outcome.turns.contains { $0.role == .system },
                      "the rejection must be fed back so the model can correct itself")
    }

    func testUnknownToolIsFedBackRatherThanRun() async {
        let store = makeStore()
        let (generate, _) = scripted([
            #"{"tool":"drop_database","args":{}}"#,
            #"{"answer":"Nothing to report."}"#,
        ])
        let outcome = await makeLoop(store: store, generate: generate).run(question: "hi")

        XCTAssertFalse(outcome.exhausted)
        XCTAssertTrue(outcome.turns.contains { $0.role == .system && $0.text.contains("drop_database") })
        XCTAssertFalse(outcome.turns.contains { $0.role == .tool },
                       "an unknown tool must never reach the router")
    }

    /// The classic small-model failure: it reads its own tool result, doesn't recognise
    /// it as an answer, and calls the same tool again forever.
    func testRepeatingAnIdenticalCallIsBlockedAndNudgedTowardAnswering() async {
        let store = makeStore()
        let (generate, _) = scripted([
            #"{"tool":"list_connectors","args":{}}"#,
            #"{"tool":"list_connectors","args":{}}"#,
            #"{"answer":"One calendar."}"#,
        ])
        let outcome = await makeLoop(store: store, generate: generate).run(question: "what's connected")

        XCTAssertEqual(outcome.answer, "One calendar.")
        XCTAssertEqual(outcome.turns.filter { $0.role == .tool }.count, 1,
                       "the tool must run once, not twice")
        XCTAssertTrue(outcome.turns.contains { $0.role == .system && $0.text.contains("already called") })
    }

    /// The repeat guard keys on the **arguments**, not the tool name.
    ///
    /// Keying on the name alone made "what's on Work and Personal" — or "today and
    /// tomorrow" — impossible to answer: the second, genuinely different call was
    /// refused as a repeat and the loop reported exhausted. This is the difference
    /// between blocking a spin and blocking multi-step work.
    func testTheSameToolRunsAgainWithDifferentArguments() async {
        let store = makeStore()
        store.add(ConnectorInstance(
            kind: .appleCalendar, label: "Personal", identity: "iCloud",
            config: .calendars(identifiers: ["cal-2"], sourceTitle: "iCloud")))

        let (generate, _) = scripted([
            #"{"tool":"list_calendar_events","args":{"connector":"Work"}}"#,
            #"{"tool":"list_calendar_events","args":{"connector":"Personal"}}"#,
            #"{"answer":"Nothing on either."}"#,
        ])
        let outcome = await makeLoop(store: store, generate: generate).run(question: "work and personal")

        XCTAssertEqual(outcome.answer, "Nothing on either.")
        XCTAssertEqual(outcome.turns.filter { $0.role == .tool }.count, 2,
                       "two different arguments are two different questions")
        XCTAssertFalse(outcome.turns.contains { $0.role == .system && $0.text.contains("already called") })
    }

    /// Argument order must not make an identical call look new — a dictionary has no
    /// order, so the key has to sort.
    func testArgumentOrderDoesNotDefeatTheRepeatGuard() async {
        let store = makeStore()
        store.add(ConnectorInstance(kind: .slack, label: "Work chat", identity: "acme"))
        // `##"…"##`: a `"#` inside the payload (`"#ops"`) would close a `#"…"#` literal.
        let (generate, _) = scripted([
            ##"{"tool":"send_message","args":{"channel":"#ops","text":"hi"}}"##,
            ##"{"tool":"send_message","args":{"text":"hi","channel":"#ops"}}"##,
            ##"{"answer":"Declined."}"##,
        ])
        let outcome = await makeLoop(store: store, generate: generate).run(question: "post to ops")

        XCTAssertEqual(outcome.turns.filter { $0.role == .tool }.count, 1)
        XCTAssertTrue(outcome.turns.contains { $0.role == .system && $0.text.contains("already called") })
    }

    /// The transcript the model sees keeps roles apart, so its own malformed attempt
    /// sits next to the correction rather than being indistinguishable from a tool's
    /// output.
    func testRenderedTranscriptLabelsEachRole() {
        let rendered = AgentLoop.render([
            .init(role: .user, text: "what's my day"),
            .init(role: .assistant, text: #"{"tool":"list_calendar_events"}"#),
            .init(role: .tool, text: "9:00 AM — Stand-up", tool: "list_calendar_events"),
        ])
        XCTAssertTrue(rendered.contains("Question: what's my day"))
        XCTAssertTrue(rendered.contains("You replied:"))
        XCTAssertTrue(rendered.contains("list_calendar_events returned:"))
    }

    // MARK: - Exhaustion

    /// Out of iterations with no answer → `exhausted`, so the caller falls back to the
    /// deterministic summary. Crucially the loop does **not** invent an answer from the
    /// partial tool output it happens to hold.
    func testRunsOutOfIterationsAndReportsExhausted() async {
        let store = makeStore()
        let (generate, calls) = scripted(Array(repeating: "not json", count: 10))
        let outcome = await makeLoop(store: store, generate: generate, maxIterations: 3)
            .run(question: "what's my day")

        XCTAssertTrue(outcome.exhausted)
        XCTAssertTrue(outcome.answer.isEmpty, "an exhausted loop must not fabricate an answer")
        XCTAssertEqual(calls(), 3, "the iteration cap is honoured exactly")
    }

    func testADeadGeneratorExhaustsWithoutSpinning() async {
        let store = makeStore()
        let outcome = await makeLoop(store: store, generate: { _, _ in nil })
            .run(question: "what's my day")
        XCTAssertTrue(outcome.exhausted)
        XCTAssertTrue(outcome.turns.isEmpty)
    }

    /// The wall-clock budget is checked before each generation, so a slow model can't
    /// hold the notch open past it.
    func testBudgetExhaustionStopsTheLoop() async {
        let store = makeStore()
        var clock = Date(timeIntervalSince1970: 0)
        let (generate, calls) = scripted(Array(repeating: "not json", count: 10))

        var loop = makeLoop(store: store, generate: { text, prompt in
            clock.addTimeInterval(30)      // each generation "takes" 30s
            return await generate(text, prompt)
        })
        loop.budget = 20
        loop.now = { clock }

        let outcome = await loop.run(question: "what's my day")
        XCTAssertTrue(outcome.exhausted)
        XCTAssertEqual(calls(), 1, "the second iteration is past the budget")
    }

    /// No connections means no tools, and a loop with no tools has nothing to offer —
    /// it must bail to the deterministic path rather than let the model answer from
    /// nothing (which is how it starts inventing meetings).
    func testNoToolsMeansNoLoop() async {
        let empty = ConnectorInstanceStore(load: false)
        empty.persistenceEnabled = false
        let router = ToolRouter(store: empty, requestApproval: { _ in .denied })
        let loop = AgentLoop(tools: [], router: router, generate: { _, _ in
            XCTFail("the model must not be called with no tools")
            return nil
        })
        let outcome = await loop.run(question: "what's my day")
        XCTAssertTrue(outcome.exhausted)
    }

    // MARK: - Registry filtering

    /// Offering a tool no connection can serve invites a call that must fail, and every
    /// failed call burns an iteration a 3B can't spare.
    func testRegistryOmitsToolsNoConnectionCanServe() {
        let store = makeStore()      // one calendar, no chat
        let names = ToolRegistry.available(store: store).map(\.name)
        XCTAssertTrue(names.contains("list_calendar_events"))
        XCTAssertTrue(names.contains("list_connectors"))
        XCTAssertFalse(names.contains("list_messages"), "no chat connector is set up")
        XCTAssertFalse(names.contains("send_message"))
    }

    func testRegistryConstrainsTheConnectorArgumentToRealLabels() {
        let store = makeStore()
        store.add(ConnectorInstance(
            kind: .appleCalendar, label: "Personal", identity: "iCloud",
            config: .calendars(identifiers: ["cal-2"], sourceTitle: "iCloud")))

        let events = ToolRegistry.available(store: store).first { $0.name == "list_calendar_events" }
        let connector = events?.parameters.first { $0.name == ToolDescriptor.instanceArgument }
        XCTAssertEqual(connector?.allowedValues.sorted(), ["Personal", "Work"])
        XCTAssertFalse(connector?.isRequired ?? true, "omitting it must mean 'merge them all'")
    }

    func testWritesCanBeWithheld() {
        let store = makeStore()
        store.add(ConnectorInstance(kind: .slack, label: "Work chat", identity: "acme"))
        let readOnly = ToolRegistry.available(store: store, includeWrites: false).map(\.name)
        XCTAssertTrue(readOnly.contains("list_messages"))
        XCTAssertFalse(readOnly.contains("send_message"))
    }

    func testPromptDescriptionMarksRequiredAndOptionalArguments() {
        let store = makeStore()
        store.add(ConnectorInstance(kind: .slack, label: "Work chat", identity: "acme"))
        let tools = ToolRegistry.available(store: store)
        let rendered = ToolRegistry.promptDescription(for: tools)

        XCTAssertTrue(rendered.contains("[connector=<"), "optional args are bracketed")
        XCTAssertTrue(rendered.contains("channel=<string>"), "required args are bare")
        XCTAssertFalse(rendered.contains("[channel="))
    }

    // MARK: - Tool routing provenance

    /// Every result names the connection that served it. Without that a transcript can't
    /// say whether "3 events" came from Work or Personal.
    func testListConnectorsNamesEveryConnection() async {
        let store = makeStore()
        store.add(ConnectorInstance(
            kind: .appleCalendar, label: "Personal", identity: "iCloud",
            config: .calendars(identifiers: ["cal-2"], sourceTitle: "iCloud")))

        let router = ToolRouter(store: store, requestApproval: { _ in .denied })
        let result = await router.run(ToolCall(tool: "list_connectors", arguments: [:]))

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.text.contains("Work"))
        XCTAssertTrue(result.text.contains("Personal"))
        XCTAssertEqual(Set(result.instanceLabels), ["Work", "Personal"])
    }

    /// **Naming a connector must actually narrow the read.**
    ///
    /// The router resolved the named instance and then called
    /// `DaySummaryService.buildAsync(store:)` with no query, which fans out across
    /// every calendar — so "what's on my work calendar" merged Personal in too and
    /// then stamped the answer "Work". There is no calendar access under `swift test`,
    /// so every consulted instance reports a gap: which instances appear in the result
    /// is exactly the observable that proves the scoping.
    func testANamedCalendarReadConsultsOnlyThatConnector() async {
        let store = makeStore()
        store.add(ConnectorInstance(
            kind: .appleCalendar, label: "Personal", identity: "iCloud",
            config: .calendars(identifiers: ["cal-2"], sourceTitle: "iCloud")))

        let router = ToolRouter(store: store, requestApproval: { _ in .denied })
        let result = await router.run(ToolCall(
            tool: "list_calendar_events", arguments: ["connector": "Work"]))

        XCTAssertFalse(result.text.contains("Personal"),
                       "a read narrowed to Work must not touch Personal: \(result.text)")
    }

    func testAnUnqualifiedCalendarReadStillMergesEveryConnector() async {
        let store = makeStore()
        store.add(ConnectorInstance(
            kind: .appleCalendar, label: "Personal", identity: "iCloud",
            config: .calendars(identifiers: ["cal-2"], sourceTitle: "iCloud")))

        let router = ToolRouter(store: store, requestApproval: { _ in .denied })
        let result = await router.run(ToolCall(tool: "list_calendar_events", arguments: [:]))

        XCTAssertTrue(result.text.contains("Work"))
        XCTAssertTrue(result.text.contains("Personal"))
    }

    /// A day other than today was simply unanswerable — the tool had no date argument
    /// at all, so "what's on tomorrow" got today's events back.
    func testAWhenPhraseMovesTheReadOffToday() async {
        let store = makeStore()
        let router = ToolRouter(store: store,
                                requestApproval: { _ in .denied },
                                now: { Date(timeIntervalSince1970: 1_754_000_000) })
        let result = await router.run(ToolCall(
            tool: "list_calendar_events", arguments: ["when": "tomorrow"]))

        XCTAssertTrue(result.text.lowercased().contains("tomorrow"),
                      "the listing must say which day it describes: \(result.text)")
    }

    func testTheCalendarToolAdvertisesADayArgument() {
        let store = makeStore()
        let events = ToolRegistry.available(store: store).first { $0.name == "list_calendar_events" }
        XCTAssertTrue(events?.parameters.contains { $0.name == "when" } ?? false)
    }

    func testRoutingAToolWithNoConnectorFails() async {
        let empty = ConnectorInstanceStore(load: false)
        empty.persistenceEnabled = false
        let router = ToolRouter(store: empty, requestApproval: { _ in .denied })
        let result = await router.run(ToolCall(tool: "list_messages", arguments: [:]))
        XCTAssertFalse(result.ok)
    }

    /// A denied write reports the user's decision plainly, so the model doesn't read it
    /// as a transient error and retry.
    func testADeniedWriteReportsTheDecisionNotAnError() async {
        let store = makeStore()
        store.add(ConnectorInstance(kind: .slack, label: "Work chat", identity: "acme"))
        let router = ToolRouter(store: store, requestApproval: { _ in .denied })
        let result = await router.run(ToolCall(
            tool: "send_message", arguments: ["channel": "#ops", "text": "hi"]))

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.text.contains("declined"))
    }

    /// "Always" must persist a grant scoped to exactly that connection and target.
    func testAlwaysAllowRecordsAScopedGrant() async {
        let store = makeStore()
        let slack = store.add(ConnectorInstance(kind: .slack, label: "Work chat", identity: "acme"))
        let router = ToolRouter(store: store, requestApproval: { _ in .allowedAlways })
        _ = await router.run(ToolCall(
            tool: "send_message", arguments: ["channel": "#ops", "text": "hi"]))

        XCTAssertEqual(store.grants.count, 1)
        let grant = store.grants[0]
        XCTAssertEqual(grant.tool, "send_message")
        XCTAssertEqual(grant.target, "#ops")
        XCTAssertEqual(grant.instanceID, slack.id)
    }

    func testAllowOnceDoesNotRecordAGrant() async {
        let store = makeStore()
        store.add(ConnectorInstance(kind: .slack, label: "Work chat", identity: "acme"))
        let router = ToolRouter(store: store, requestApproval: { _ in .allowedOnce })
        _ = await router.run(ToolCall(
            tool: "send_message", arguments: ["channel": "#ops", "text": "hi"]))
        XCTAssertTrue(store.grants.isEmpty)
    }
}
