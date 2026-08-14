import XCTest

@testable import WhisperMaster

/// The Traces surface, pinned at the layer that decides what it *says*.
///
/// Everything asserted here is pure or store-level: the stage chain, the polish
/// verdict's reason, the call journal, the cap and the round-trip. The view is not
/// under test — but every claim the view makes is, which is the point. A trace that
/// says "unchanged" about a pass that changed something is worse than no trace,
/// because it is evidence pointing the wrong way.
@MainActor
final class TraceTests: XCTestCase {

    private func builder(raw: String = "hello there") -> DictationTraceBuilder {
        DictationTraceBuilder(
            engine: .slidingWindow,
            raw: raw,
            usedSalvage: false,
            startedAt: Date(timeIntervalSince1970: 1_760_000_000),
            duration: 4)
    }

    private func store() -> TraceStore {
        // A throwaway suite, so nothing here can read or write the real preferences.
        let defaults = UserDefaults(suiteName: "trace-tests-\(UUID().uuidString)")!
        return TraceStore(load: true, defaults: defaults)
    }

    // MARK: - The stage chain

    func testAStageIsComparedAgainstThePreviousStageNotTheRawTranscript() {
        var chain = builder(raw: "one")
        chain.stage("First", "two")
        chain.stage("Second", "two")
        let trace = chain.build(finalText: "two")

        XCTAssertEqual(trace.stages.map(\.changed), [true, false],
                       "The second pass left the text exactly as the first pass did, so it "
                           + "must read as unchanged even though it differs from the raw text.")
    }

    func testASkippedPassIsRecordedWithItsReasonRatherThanOmitted() {
        var chain = builder(raw: "hello")
        chain.skipped("Filler words", why: "Switched off in Settings.")
        let trace = chain.build(finalText: "hello")

        // Omitting it would read as "this pass doesn't exist", which is the opposite
        // of what a switched-off pass means.
        XCTAssertEqual(trace.stages.count, 1)
        XCTAssertFalse(trace.stages[0].changed)
        XCTAssertEqual(trace.stages[0].note, "Switched off in Settings.")
        XCTAssertEqual(trace.stages[0].text, "hello", "A skipped pass carries the text through.")
    }

    func testFixNoteIsPluralSafeAndSilentAtZero() {
        XCTAssertEqual(DictationTraceBuilder.fixNote(0, "removed"), "")
        XCTAssertEqual(DictationTraceBuilder.fixNote(1, "removed"), "1 removed")
        XCTAssertEqual(DictationTraceBuilder.fixNote(3, "matched term"), "3 matched terms")
    }

    func testLongTextIsClampedSoATraceCannotBloatThePreferencesFile() {
        let long = String(repeating: "a", count: TraceText.limit + 500)
        let clamped = TraceText.clamp(long)
        XCTAssertLessThan(clamped.count, long.count)
        XCTAssertTrue(clamped.hasSuffix("(truncated)"))
        XCTAssertEqual(TraceText.clamp("short"), "short", "Normal text is never touched.")
    }

    // MARK: - What the row claims was delivered

    func testDeliveredTextPrefersThePolishOnlyWhenThePolishWasActuallyApplied() {
        var trace = builder().build(finalText: "deterministic")
        trace.polish = PolishTrace(
            outcome: .rejected, before: "deterministic", after: "a rewrite nobody got")
        XCTAssertEqual(trace.deliveredText, "deterministic",
                       "A rejected rewrite never reached the user, so the row must not show it.")

        trace.polish = PolishTrace(outcome: .applied, before: "deterministic", after: "polished")
        XCTAssertEqual(trace.deliveredText, "polished")
    }

    func testAnUnknownDeliveryRouteReadsAsItselfRatherThanDisappearing() {
        XCTAssertEqual(DeliveryTrace(route: "native", appName: "Linear").headline,
                       "Typed into Linear")
        XCTAssertEqual(DeliveryTrace(route: "somethingNew").headline, "somethingNew")
        XCTAssertFalse(DeliveryTrace(route: "clipboard").reachedTheCursor)
        XCTAssertTrue(DeliveryTrace(route: "terminal").reachedTheCursor)
    }

    // MARK: - The store

    func testTracesAreNewestFirstAndCapped() {
        let entries = (0..<(TraceStore.limit + 5)).reduce(into: [Int]()) { list, value in
            list = TraceStore.capped(value, in: list)
        }
        XCTAssertEqual(entries.count, TraceStore.limit)
        XCTAssertEqual(entries.first, TraceStore.limit + 4, "Newest first.")
    }

    func testPolishAndDeliveryAttachToARowThatIsAlreadyOnScreen() {
        let traces = store()
        let trace = builder().build(finalText: "hello")
        traces.record(trace)

        traces.attachPolish(trace.id, PolishTrace(outcome: .applied, after: "Hello."))
        traces.attachDelivery(trace.id, DeliveryTrace(route: "native", appName: "Notes"))

        XCTAssertEqual(traces.dictation.first?.polish?.outcome, .applied)
        XCTAssertEqual(traces.dictation.first?.delivery?.route, "native")
        XCTAssertEqual(traces.dictation.first?.deliveredText, "Hello.")
    }

    func testAttachingToATraceThatHasAgedOutIsANoOpRatherThanResurrectingIt() {
        let traces = store()
        let dropped = builder().build(finalText: "gone")
        traces.attachPolish(dropped.id, PolishTrace(outcome: .applied, after: "Gone."))
        XCTAssertTrue(traces.dictation.isEmpty)
    }

    func testTracesSurviveARelaunch() {
        let defaults = UserDefaults(suiteName: "trace-roundtrip-\(UUID().uuidString)")!
        let first = TraceStore(load: true, defaults: defaults)
        first.record(builder().build(finalText: "persisted"))
        first.record(AssistantTrace(asked: "what's on today", answer: "Two meetings."))

        let reopened = TraceStore(load: true, defaults: defaults)
        XCTAssertEqual(reopened.dictation.first?.finalText, "persisted")
        XCTAssertEqual(reopened.assistant.first?.answer, "Two meetings.")
    }

    func testSeedingDoesNotPersist() {
        let defaults = UserDefaults(suiteName: "trace-seed-\(UUID().uuidString)")!
        let traces = TraceStore(load: true, defaults: defaults)
        traces.seed(dictation: [builder().build(finalText: "mock")])

        // The snapshot renderer runs inside a real app process; a seed that persisted
        // would replace a real user's traces with the mock ones.
        XCTAssertTrue(TraceStore(load: true, defaults: defaults).dictation.isEmpty)
    }

    func testClearingOneTabLeavesTheOtherAlone() {
        let traces = store()
        traces.record(builder().build(finalText: "kept"))
        traces.record(AssistantTrace(asked: "cleared"))

        traces.clearAssistant()
        XCTAssertEqual(traces.dictation.count, 1)
        XCTAssertTrue(traces.assistant.isEmpty)
    }

    // MARK: - The assistant trace

    func testTheTakenDecisionIsTheOneTheRowBadges() {
        let trace = AssistantTrace(decisions: [
            TraceDecision(title: "Agent", detail: "Skipped — no model.", taken: false),
            TraceDecision(title: "Day summary", detail: "Skipped.", taken: false),
            TraceDecision(title: "Filed as a note", detail: "Kept the words.", taken: true),
        ])
        XCTAssertEqual(trace.takenDecision?.title, "Filed as a note")
    }

    func testTouchedConnectorsIgnoresLocalToolsAndDeduplicates() {
        let trace = AssistantTrace(calls: [
            ToolCallTrace(tool: "create_note", connectors: []),
            ToolCallTrace(tool: "list_mail", connectors: ["corkkam"]),
            ToolCallTrace(tool: "list_calendar_events", connectors: ["corkkam", "Work"]),
        ])
        XCTAssertEqual(trace.touchedConnectors, ["corkkam", "Work"])
    }

    /// Traces already on disk were written before these fields existed. A bare
    /// non-optional field here would fail the decode of the whole list — the same
    /// class of bug that empties a user's notes, and cheap to pin.
    func testATraceWrittenBeforeTheNewFieldsExistedStillDecodes() throws {
        let old = """
        {"id":"\(UUID().uuidString)","askedAt":760000000,"heard":"h","asked":"a",
         "stages":[],"decisions":[],"connectorsAllowed":true,"toolsOffered":[],
         "calls":[{"id":"\(UUID().uuidString)","tool":"send_message","arguments":{},
                   "connectors":[],"ok":true,"result":"Sent.","milliseconds":420}],
         "answer":"Sent.","provenance":"Sent to Work chat","createdSomething":true,
         "milliseconds":900}
        """
        let trace = try JSONDecoder().decode(AssistantTrace.self, from: Data(old.utf8))

        XCTAssertEqual(trace.answer, "Sent.")
        XCTAssertNil(trace.turns)
        XCTAssertEqual(trace.calls.first?.milliseconds, 420)
        XCTAssertNil(trace.calls.first?.approvalMilliseconds)
        XCTAssertNil(trace.calls.first?.authorization)
    }

    func testAnAuthorizationBadgeSaysWhichOfTheFiveWaysItWasPermitted() {
        XCTAssertEqual(ToolAuthorization.standingGrant.label, "standing grant")
        XCTAssertEqual(ToolAuthorization.timedOut.label, "no answer")
        // The row tints these two, because neither is permission.
        XCTAssertTrue(ToolAuthorization.denied.isRefusal)
        XCTAssertTrue(ToolAuthorization.timedOut.isRefusal)
        XCTAssertFalse(ToolAuthorization.allowedAlways.isRefusal)
    }

    func testATurnNamesWhoSpokeAndAnUnknownRoleReadsAsItself() {
        XCTAssertEqual(TraceTurn(role: "model", text: "{}").speaker, "The model said")
        XCTAssertEqual(TraceTurn(role: "system", text: "no").speaker, "It was told")
        XCTAssertEqual(TraceTurn(role: "oracle", text: "?").speaker, "oracle")
    }

    func testACallRendersAsTheCallThatWasActuallyMade() {
        let call = ToolCallTrace(tool: "list_mail", arguments: ["connector": "corkkam"])
        XCTAssertEqual(call.signature, "list_mail connector=corkkam")
        XCTAssertEqual(ToolCallTrace(tool: "list_reminders").signature, "list_reminders")
        XCTAssertTrue(ToolCallTrace(tool: "create_note").isLocal)
        XCTAssertTrue(ToolCallTrace(tool: "send_message").isWrite)
        XCTAssertFalse(ToolCallTrace(tool: "list_mail").isWrite)
    }

    // MARK: - The polish verdict

    func testTheGuardsVerdictAgreesWithAcceptAndCarriesAReason() {
        let cases: [(original: String, cleaned: String, rephrase: Bool)] = [
            ("um lets ship the thing", "Let's ship the thing.", false),
            ("what is the capital of france", "The capital of France is Paris.", true),
            ("say hello to the team about the launch", "Hello.", false),
            ("clean this up", "```swift\nprint()\n```", false),
            ("anything at all", "", false),
        ]
        for item in cases {
            let verdict = CleanupFaithfulnessGuard.verdict(
                original: item.original, cleaned: item.cleaned, allowRephrase: item.rephrase)
            let accepted = CleanupFaithfulnessGuard.accept(
                original: item.original, cleaned: item.cleaned, allowRephrase: item.rephrase)
            XCTAssertEqual(verdict.isAccepted, accepted,
                           "verdict and accept must never disagree for \(item.cleaned)")
            XCTAssertFalse(verdict.reason.isEmpty, "Every verdict explains itself.")
        }
    }

    func testARejectionNamesWhatWentWrong() {
        XCTAssertEqual(
            CleanupFaithfulnessGuard.verdict(original: "clean this", cleaned: "```code```"),
            .codeFence)
        XCTAssertEqual(
            CleanupFaithfulnessGuard.verdict(original: "hello", cleaned: "   "),
            .empty)
        // Polish mode's anti-answer rule: a name the input never had.
        XCTAssertEqual(
            CleanupFaithfulnessGuard.verdict(
                original: "what is the capital of france",
                cleaned: "The capital of France is Paris.",
                allowRephrase: true),
            .inventedEntity)
    }

    func testTheInventedWordNamedIsStableForTheSamePair() {
        // Two invented words, and a length ratio well inside the band so the content
        // rule is what fires. Dictionary iteration order is not stable between runs,
        // so a reason built by taking "whichever came first" would change under the
        // reader — the sort in `verdict` is what this pins.
        let original = "buy some milk from the shop today"
        let cleaned = "Buy some milk from the shop today zebra apple"
        let first = CleanupFaithfulnessGuard.verdict(original: original, cleaned: cleaned)
        let second = CleanupFaithfulnessGuard.verdict(original: original, cleaned: cleaned)

        XCTAssertEqual(first, second)
        guard case .inventedWord(let word) = first else {
            return XCTFail("Expected the content rule to fire, got \(first)")
        }
        XCTAssertTrue(word.hasPrefix("appl"),
                      "Alphabetically first of the invented stems, so the reason is fixed "
                          + "rather than whichever the dictionary yielded first.")
    }

    func testAPolishCanBeRestampedWhenTheInPlaceEditFails() {
        let accepted = PolishTrace(outcome: .applied, before: "a", after: "b", reason: "Fine.")
        let settled = accepted.settled(as: .notApplied, reason: "The field refused it.")
        XCTAssertEqual(settled.outcome, .notApplied)
        XCTAssertEqual(settled.reason, "The field refused it.")
        XCTAssertEqual(settled.after, "b", "The rewrite itself is kept — it's the evidence.")
        XCTAssertTrue(settled.outcome.isFailure)
        XCTAssertFalse(PolishTrace.off.outcome.isFailure,
                       "Switched off is the expected state, not a failure.")
    }
}

/// The tool journal: what the assistant tab reads to say which connector served what.
@MainActor
final class ToolJournalTests: XCTestCase {
    private func notesStore() -> NotesStore {
        NotesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-journal-\(UUID()).json"), load: false)
    }

    private func router(connectors: (any AgentToolRunning)? = nil) -> CommandToolRouter {
        CommandToolRouter(
            local: LocalToolRunner(notes: notesStore()),
            connectors: connectors,
            now: { Date(timeIntervalSince1970: 1_760_000_000) })
    }

    /// A write that sat on the consent card is not a slow connector. Charging the
    /// user's own thinking time to the call made every approved write look like a
    /// minute of provider latency, and sent anyone reading this page after the wrong
    /// thing.
    func testTheApprovalWaitIsRecordedApartFromTheCallItWaitedIn() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_760_000_000))
        let subject = CommandToolRouter(
            local: LocalToolRunner(notes: notesStore()),
            connectors: StubConnectorRouter(
                ToolResult(ok: true, text: "Sent to #ops.", instanceLabels: ["Work chat"],
                           authorization: .allowedOnce, approvalMilliseconds: 58_000),
                whileRunning: { clock.advance(59) }),
            now: { clock.now })

        _ = await subject.run(ToolCall(tool: "send_message",
                                       arguments: ["channel": "#ops", "text": "hi"]))

        XCTAssertEqual(subject.journal[0].milliseconds, 1_000,
                       "the call itself took a second; the other 58s was the user deciding")
        XCTAssertEqual(subject.journal[0].approvalMilliseconds, 58_000)
        XCTAssertEqual(subject.journal[0].authorization, .allowedOnce,
                       "how a write was permitted is part of what happened")
    }

    /// A read has nothing to authorize, so the row must not claim it was permitted.
    func testAReadIsJournalledWithNoAuthorization() async {
        let subject = router(connectors: StubConnectorRouter(
            ToolResult(ok: true, text: "Nothing to report.", instanceLabels: ["corkkam"])))
        _ = await subject.run(ToolCall(tool: "list_mail", arguments: [:]))

        XCTAssertNil(subject.journal[0].authorization)
        XCTAssertEqual(subject.journal[0].approvalMilliseconds, 0, "no card, no wait")
    }

    /// The gap the model might not pass on. Named once, in call order.
    func testConnectorsThatCouldNotBeReadAreCollectedAcrossCalls() async {
        let subject = router(connectors: StubConnectorRouter(
            ToolResult(ok: true, text: "[Work] couldn't be read: sign in again.",
                       instanceLabels: [], unreadable: ["Work"])))
        _ = await subject.run(ToolCall(tool: "list_mail", arguments: [:]))
        _ = await subject.run(ToolCall(tool: "list_calendar_events", arguments: [:]))

        XCTAssertEqual(subject.unreadable, ["Work"], "the same connection is named once")
    }

    func testALocalCallIsJournalledWithItsArgumentsAndResult() async {
        let subject = router()
        _ = await subject.run(ToolCall(tool: "create_note", arguments: ["body": "buy milk"]))

        XCTAssertEqual(subject.journal.count, 1)
        XCTAssertEqual(subject.journal[0].tool, "create_note")
        XCTAssertEqual(subject.journal[0].arguments["body"], "buy milk")
        XCTAssertTrue(subject.journal[0].ok)
        XCTAssertFalse(subject.journal[0].result.isEmpty)
    }

    func testACallThatFailedIsJournalledToo() async {
        // No connector router at all — the state a user is in with the assistant's
        // connector switch off, and precisely the failure the trace must show.
        let subject = router()
        _ = await subject.run(ToolCall(tool: "list_mail", arguments: [:]))

        XCTAssertEqual(subject.journal.count, 1)
        XCTAssertFalse(subject.journal[0].ok)
        XCTAssertEqual(subject.journal[0].result, "No connector is set up for that yet.")
    }

    func testTheJournalKeepsCallOrderAndConnectorProvenance() async {
        let subject = router(connectors: StubConnectorRouter(
            ToolResult(ok: true, text: "Design review notes (unread)",
                       instanceLabels: ["corkkam"])))
        _ = await subject.run(ToolCall(tool: "list_reminders", arguments: [:]))
        _ = await subject.run(ToolCall(tool: "list_mail", arguments: [:]))

        XCTAssertEqual(subject.journal.map(\.tool), ["list_reminders", "list_mail"])
        XCTAssertEqual(subject.journal[1].connectors, ["corkkam"])
        XCTAssertTrue(subject.journal[0].connectors.isEmpty,
                      "A local tool has no connector to credit.")
    }

    /// A tool that ran away with a page of output can't be allowed to store it in full
    /// forty times over — the journal clamps what it keeps the same way every other
    /// slot on a trace does.
    func testALongToolResultIsClampedInTheJournal() async {
        let long = String(repeating: "x", count: TraceText.limit + 200)
        let subject = router(connectors: StubConnectorRouter(
            ToolResult(ok: true, text: long, instanceLabels: ["corkkam"])))
        _ = await subject.run(ToolCall(tool: "list_mail", arguments: [:]))

        XCTAssertTrue(subject.journal[0].result.hasSuffix("(truncated)"))
        XCTAssertLessThan(subject.journal[0].result.count, long.count)
    }
}
