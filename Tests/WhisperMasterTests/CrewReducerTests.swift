import XCTest

@testable import WhisperMaster

/// The same 10 lines as `crew-kit/spec/events-golden.jsonl`. Keep the two in step.
let crewGoldenEvents = """
{"v":1,"ts":"2026-11-27T14:00:00.000Z","src":"crew","event":"run.start","session":"s1","agent":"juno","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:01.000Z","src":"claude","event":"session.start","session":"s1","agent":"juno","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:05.000Z","src":"crew","event":"huddle.start","session":"s1","agent":"juno","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":["pm","c-input"]}
{"v":1,"ts":"2026-11-27T14:00:06.000Z","src":"claude","event":"agent.start","session":"s1","agent":"pm","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:20.000Z","src":"claude","event":"agent.stop","session":"s1","agent":"pm","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:30.000Z","src":"crew","event":"huddle.end","session":"s1","agent":"juno","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":["pm","c-input"]}
{"v":1,"ts":"2026-11-27T14:00:31.000Z","src":"claude","event":"agent.start","session":"s1","agent":"qa","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:40.000Z","src":"claude","event":"agent.stop","session":"s1","agent":"qa","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:41.000Z","src":"claude","event":"agent.start","session":"s1","agent":"c-input","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:42.000Z","src":"claude","event":"tool.start","session":"s1","agent":"c-input","project":"/tmp/crew-golden","tool":"Bash","kind":"test","note":null,"agents":[]}
"""

final class CrewReducerTests: XCTestCase {

    private let project = "/p"
    private let base = crewDate("2026-11-27T14:00:00.000Z")

    private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    private func event(
        _ name: String, _ agent: String = "a", at seconds: TimeInterval = 0, project: String? = nil,
        kind: String? = nil, note: String? = nil, session: String? = nil, agents: [String] = []
    ) -> CrewEvent {
        CrewEvent(
            ts: at(seconds), event: name, session: session, agent: agent, project: project ?? self.project,
            kind: kind, note: note, agents: agents)
    }

    private func reduce(_ events: [CrewEvent]) -> CrewReducer {
        var r = CrewReducer()
        for e in events { r.apply(e) }
        return r
    }

    private func entry(_ r: CrewReducer, _ agent: String = "a", project: String? = nil) -> CrewReducer.Entry? {
        r.entries[CrewReducer.key(project: project ?? self.project, agent: agent)]
    }

    private func state(_ r: CrewReducer, _ agent: String = "a") -> AgentFaceState? {
        entry(r, agent)?.state
    }

    private func identity(_ project: String, _ agent: String) -> AgentFaceIdentity? {
        AgentFaceIdentity(name: agent, role: .component)
    }

    // MARK: Event table

    func testThinkingEvents() {
        for name in ["session.start", "run.start", "agent.start", "prompt"] {
            let r = reduce([event(name, at: 3)])
            XCTAssertEqual(state(r), .thinking, name)
            XCTAssertEqual(entry(r)?.since, at(3), name)
        }
    }

    func testContextClearKeepsStateAndStampsTime() {
        let r = reduce([event("tool.start", kind: "test"), event("context.clear", at: 4, note: "clear")])
        XCTAssertEqual(state(r), .working)
        XCTAssertEqual(entry(r)?.contextClearedAt, at(4))
        XCTAssertEqual(entry(r)?.lastEventAt, at(4))
    }

    func testToolStartDetailForEachKind() {
        let expected: [String?: String?] = [
            "test": "tests", "build": "build", "git": "git", "search": "search", "edit": "editing",
            "read": "reading", "web": "web", "agent": "delegating", "other": nil, nil: nil,
        ]
        for (kind, detail) in expected {
            let r = reduce([event("tool.start", kind: kind)])
            XCTAssertEqual(state(r), .working, kind ?? "nil")
            XCTAssertEqual(entry(r)?.detail, detail, kind ?? "nil")
        }
    }

    func testToolEndAndFailBackToThinkingWithoutDetail() {
        for name in ["tool.end", "tool.fail"] {
            let r = reduce([event("tool.start", kind: "build"), event(name, at: 1)])
            XCTAssertEqual(state(r), .thinking, name)
            XCTAssertNil(entry(r)?.detail, name)
            XCTAssertEqual(entry(r)?.since, at(1), name)
        }
    }

    func testNeedsInputIsWaiting() {
        XCTAssertEqual(state(reduce([event("needs.input", note: "permission")])), .waiting)
    }

    func testHuddleStartAndRoundSetEveryoneDiscussing() {
        for name in ["huddle.start", "huddle.round"] {
            let r = reduce([event(name, "lead", session: "s7", agents: ["pm", "qa"])])
            for id in ["lead", "pm", "qa"] {
                XCTAssertEqual(state(r, id), .discussing, "\(name) \(id)")
                XCTAssertEqual(entry(r, id)?.discussionGroup, "huddle:s7")
            }
        }
    }

    func testHuddleGroupFallsBackToLeadWithoutSession() {
        let r = reduce([event("huddle.start", "lead", agents: ["pm"])])
        XCTAssertEqual(entry(r, "pm")?.discussionGroup, "huddle:lead")
    }

    func testHuddleEndLeadThinksOthersIdleGroupCleared() {
        let r = reduce([
            event("huddle.start", "lead", session: "s", agents: ["pm", "qa"]),
            event("huddle.end", "lead", at: 5, session: "s", agents: ["pm", "qa"]),
        ])
        XCTAssertEqual(state(r, "lead"), .thinking)
        XCTAssertEqual(state(r, "pm"), .idle)
        XCTAssertEqual(state(r, "qa"), .idle)
        for id in ["lead", "pm", "qa"] { XCTAssertNil(entry(r, id)?.discussionGroup) }
    }

    func testAgentStopAndTurnEndAreDone() {
        for name in ["agent.stop", "turn.end"] {
            XCTAssertEqual(state(reduce([event("prompt"), event(name, at: 1)])), .done, name)
        }
    }

    func testRunEndNotes() {
        let expected: [String: AgentFaceState] = [
            "ok": .done, "changed": .done, "no change": .done, "needs approval": .waiting,
            "error": .error, "crash": .error, "blocked": .error,
            "budget": .overBudget, "window": .overBudget, "stopped": .asleep,
        ]
        for (note, want) in expected {
            let r = reduce([event("run.start"), event("run.end", at: 9, note: note)])
            XCTAssertEqual(state(r), want, note)
            XCTAssertEqual(entry(r)?.contextClearedAt, at(9), note)
        }
    }

    func testTurnFailIsError() {
        XCTAssertEqual(state(reduce([event("turn.fail")])), .error)
    }

    func testBudgetOverIsOverBudget() {
        XCTAssertEqual(state(reduce([event("budget.over", note: "budget")])), .overBudget)
    }

    func testStopOnAndOffTouchOnlyThatProject() {
        let r = reduce([
            event("prompt", "a"), event("tool.start", "b", kind: "test"),
            event("prompt", "x", project: "/other"),
            event("stop.on", "a", at: 2),
        ])
        XCTAssertEqual(state(r, "a"), .asleep)
        XCTAssertEqual(state(r, "b"), .asleep)
        XCTAssertNil(entry(r, "b")?.detail)
        XCTAssertEqual(entry(r, "x", project: "/other")?.state, .thinking)
        var r2 = r
        r2.apply(event("stop.off", "a", at: 3))
        XCTAssertEqual(state(r2, "a"), .idle)
        XCTAssertEqual(state(r2, "b"), .idle)
        XCTAssertEqual(entry(r2, "x", project: "/other")?.state, .thinking)
    }

    func testSessionEnd() {
        for keep: AgentFaceState in [.done, .error, .overBudget] {
            var r = reduce([event("prompt")])
            switch keep {
            case .done: r.apply(event("turn.end", at: 1))
            case .error: r.apply(event("turn.fail", at: 1))
            default: r.apply(event("budget.over", at: 1))
            }
            r.apply(event("session.end", at: 2))
            XCTAssertEqual(state(r), keep)
        }
        for name in ["prompt", "needs.input"] {
            let r = reduce([event(name), event("session.end", at: 2)])
            XCTAssertEqual(state(r), .idle, name)
        }
        let working = reduce([event("tool.start", kind: "test"), event("session.end", at: 2)])
        XCTAssertEqual(state(working), .idle)
        XCTAssertNil(entry(working)?.detail)
    }

    func testGuardLoopAndUnknownKeepStateButStampTime() {
        for name in ["guard.deny", "loop.start", "loop.end", "something.new"] {
            let r = reduce([event("tool.start", kind: "edit"), event(name, at: 7)])
            XCTAssertEqual(state(r), .working, name)
            XCTAssertEqual(entry(r)?.detail, "editing", name)
            XCTAssertEqual(entry(r)?.lastEventAt, at(7), name)
            XCTAssertEqual(entry(r)?.since, at(0), name)
        }
    }

    func testUnknownEventDoesNotCreateAKey() {
        XCTAssertTrue(reduce([event("something.new")]).entries.isEmpty)
    }

    func testSinceMovesOnlyWhenStateChanges() {
        let r = reduce([event("prompt"), event("tool.end", at: 5)])
        XCTAssertEqual(entry(r)?.since, at(0))
        XCTAssertEqual(entry(r)?.lastEventAt, at(5))
    }

    // MARK: Timeouts

    private func ticked(_ events: [CrewEvent], at seconds: TimeInterval, stop: Bool = false) -> CrewReducer {
        var r = reduce(events)
        r.tick(now: at(seconds), globalStop: stop)
        return r
    }

    func testDoneBecomesIdleAfterTenSeconds() {
        let e = [event("turn.end")]
        XCTAssertEqual(state(ticked(e, at: 9)), .done)
        XCTAssertEqual(state(ticked(e, at: 10)), .idle)
    }

    func testThinkingAndDiscussingBecomeIdleAfterFiveMinutes() {
        let thinking = [event("prompt")]
        XCTAssertEqual(state(ticked(thinking, at: 299)), .thinking)
        XCTAssertEqual(state(ticked(thinking, at: 300)), .idle)
        let discussing = [event("huddle.start", "a", agents: ["b"])]
        XCTAssertEqual(state(ticked(discussing, at: 299)), .discussing)
        let r = ticked(discussing, at: 300)
        XCTAssertEqual(state(r), .idle)
        XCTAssertNil(entry(r)?.discussionGroup)
    }

    func testWorkingBecomesIdleAfterFifteenMinutes() {
        let e = [event("tool.start", kind: "test")]
        XCTAssertEqual(state(ticked(e, at: 899)), .working)
        XCTAssertEqual(state(ticked(e, at: 900)), .idle)
    }

    func testWaitingHoldsThenSleepsAfterThirtyMinutes() {
        let e = [event("needs.input")]
        XCTAssertEqual(state(ticked(e, at: 1799)), .waiting)
        XCTAssertEqual(state(ticked(e, at: 1800)), .asleep)
    }

    func testErrorAndOverBudgetHoldThenSleepAfterSixtyMinutes() {
        for name in ["turn.fail", "budget.over"] {
            let e = [event(name)]
            let held = state(ticked(e, at: 3599))
            XCTAssertTrue(held == .error || held == .overBudget, name)
            XCTAssertEqual(state(ticked(e, at: 3600)), .asleep, name)
        }
    }

    func testIdleSleepsAfterThirtyMinutes() {
        let e = [event("huddle.end", "a", agents: ["b"])]
        XCTAssertEqual(entry(reduce(e), "b")?.state, .idle)
        var r = reduce(e)
        r.tick(now: at(1799), globalStop: false)
        XCTAssertEqual(entry(r, "b")?.state, .idle)
        r.tick(now: at(1800), globalStop: false)
        XCTAssertEqual(entry(r, "b")?.state, .asleep)
    }

    func testAsleepKeyIsRemovedAfterSixHours() {
        let e = [event("run.end", note: "stopped")]
        let six: TimeInterval = 6 * 3600
        XCTAssertEqual(state(ticked(e, at: six - 1)), .asleep)
        XCTAssertNil(entry(ticked(e, at: six)))
    }

    func testLongGapCascadesToAsleepInOneTick() {
        XCTAssertEqual(state(ticked([event("prompt")], at: 3 * 3600)), .asleep)
    }

    func testGlobalStopPutsEveryKeyToSleep() {
        let r = ticked([event("tool.start", kind: "test"), event("needs.input", "b")], at: 1, stop: true)
        XCTAssertEqual(state(r, "a"), .asleep)
        XCTAssertEqual(state(r, "b"), .asleep)
        XCTAssertNil(entry(r, "a")?.detail)
    }

    // MARK: Items

    func testItemIdIsProjectSlashAgentAndCarriesFields() throws {
        let r = reduce([event("tool.start", "c-input", at: 2, kind: "build"), event("context.clear", "c-input", at: 3)])
        let items = r.items(roster: identity)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.id, "/p/c-input")
        XCTAssertEqual(item.identity.name, "c-input")
        XCTAssertEqual(item.state, .working)
        XCTAssertEqual(item.detail, "build")
        XCTAssertEqual(item.since, at(2))
        XCTAssertEqual(item.contextClearedAt, at(3))
    }

    func testHelperIsDropped() {
        let r = reduce([event("prompt", "scout"), event("prompt", "pm")])
        let items = r.items { _, agent in agent == "scout" ? nil : AgentFaceIdentity(name: agent, role: .pm) }
        XCTAssertEqual(items.map(\.id), ["/p/pm"])
    }

    func testItemsAreNotFilteredByVisibility() {
        let r = reduce([event("prompt", "a"), event("huddle.end", "b", agents: ["c"])])
        XCTAssertEqual(r.items(roster: identity).count, 3)
    }

    // MARK: Golden file

    func testGoldenStatesAtFourteenFortyThree() throws {
        var r = CrewReducer()
        for e in crewGoldenList() { r.apply(e) }
        r.tick(now: crewDate("2026-11-27T14:00:43.000Z"), globalStop: false)
        let project = "/tmp/crew-golden"
        func item(_ agent: String) -> CrewReducer.Entry? { r.entries[CrewReducer.key(project: project, agent: agent)] }
        XCTAssertEqual(item("juno")?.state, .thinking)
        XCTAssertEqual(item("pm")?.state, .idle)
        XCTAssertEqual(item("c-input")?.state, .working)
        XCTAssertEqual(item("c-input")?.detail, "tests")
        XCTAssertEqual(item("qa")?.state, .done)
        XCTAssertEqual(r.entries.count, 4)
    }

    func testReducerSourceImportsNoAppKit() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WhisperMaster/Crew/CrewReducer.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("import AppKit"))
        XCTAssertFalse(text.contains("import SwiftUI"))
    }
}
