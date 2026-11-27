import XCTest

@testable import WhisperMaster

@MainActor
final class CrewAgentsTests: XCTestCase {
    private var home: URL!
    private var project: URL!
    private var events: URL { home.appendingPathComponent("events.jsonl") }
    private var clock = crewDate("2026-11-27T14:00:00.000Z")
    private var crew: CrewAgents!

    override func setUpWithError() throws {
        home = try CrewTestFiles.makeFolder()
        project = try CrewTestFiles.makeFolder()
        try crewWriteRoster(
            project,
            agents: """
            {"id":"lead","role":"lead","name":"Atlas"},
            {"id":"pm","role":"pm","name":"Maya"},
            {"id":"c-input","role":"component","name":"Tapper"},
            {"id":"scout","role":"helper","name":"Scout"}
            """)
        clock = crewDate("2026-11-27T14:00:00.000Z")
        crew = CrewAgents(crewHome: home, now: { [unowned self] in self.clock })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: project)
    }

    private func emit(_ event: String, _ agent: String, kind: String? = nil) throws {
        let second = Int(clock.timeIntervalSince(crewDate("2026-11-27T14:00:00.000Z")))
        try CrewTestFiles.append(
            CrewTestFiles.line(event, agent: agent, project: project.path, second: second, kind: kind), to: events)
    }

    private func advance(_ seconds: TimeInterval) async {
        clock = clock.addingTimeInterval(seconds)
        await crew.step()
    }

    private func ids() -> [String] { crew.items.map { $0.id.components(separatedBy: "/").last ?? "" } }

    // MARK: Basics

    func testDormantUntilStepped() {
        XCTAssertTrue(crew.items.isEmpty)
        XCTAssertFalse(crew.isAvailable)
        XCTAssertFalse(crew.isActive)
    }

    func testIsAvailableWhenTheEventsFileExists() async throws {
        await crew.step()
        XCTAssertFalse(crew.isAvailable)
        try emit("prompt", "lead")
        await crew.step()
        XCTAssertTrue(crew.isAvailable)
    }

    func testCrewHomeFromEnvironment() {
        let moved = CrewAgents.defaultHome(environment: ["CREW_HOME": "/tmp/somewhere-else"])
        XCTAssertEqual(moved.path, "/tmp/somewhere-else")
        XCTAssertTrue(CrewAgents.defaultHome(environment: [:]).path.hasSuffix("/.crew"))
        XCTAssertTrue(CrewAgents.defaultHome(environment: ["CREW_HOME": ""]).path.hasSuffix("/.crew"))
    }

    // MARK: Visibility

    func testLeadAndBusyAgentsShowWhileActive() async throws {
        try emit("prompt", "lead")
        try emit("tool.start", "c-input", kind: "test")
        await crew.step()
        XCTAssertTrue(crew.isActive)
        XCTAssertEqual(Set(ids()), ["lead", "c-input"])
        XCTAssertEqual(crew.items.first { $0.id.hasSuffix("/c-input") }?.detail, "tests")
    }

    func testIdleAgentIsHiddenButTheLeadStaysWhileActive() async throws {
        try emit("prompt", "lead")
        try emit("turn.end", "pm")
        await crew.step()
        XCTAssertEqual(Set(ids()), ["lead", "pm"])
        // The pm finished 10 s ago and is idle. The lead still thinks, so the rail stays.
        await advance(10)
        XCTAssertTrue(crew.isActive)
        XCTAssertEqual(ids(), ["lead"])
    }

    func testLeadStaysWhileItIsIdleInsideTheHold() async throws {
        try emit("turn.end", "lead")
        await crew.step()
        XCTAssertEqual(ids(), ["lead"])
        await advance(10)  // done -> idle
        XCTAssertTrue(crew.isActive, "inside the 60 s hold")
        XCTAssertEqual(ids(), ["lead"])
        await advance(49)
        XCTAssertEqual(ids(), ["lead"])
    }

    func testItemsAreEmptyAfterTheHold() async throws {
        try emit("turn.end", "lead")
        await crew.step()  // done at t0, busy
        await advance(10)  // idle. last busy moment was the first step at t0.
        await advance(49)  // t = 59 s
        XCTAssertTrue(crew.isActive)
        await advance(1)  // t = 60 s
        XCTAssertFalse(crew.isActive)
        XCTAssertTrue(crew.items.isEmpty)
    }

    func testNotInTheRosterIsStillShownWhileBusy() async throws {
        try emit("prompt", "stranger")
        await crew.step()
        XCTAssertEqual(Set(ids()), ["lead", "stranger"])
    }

    func testLeadShowsWhenOnlyAComponentHasEvents() async throws {
        // Spec 12.4: the lead of each project with any key shows while the rail is visible.
        try emit("tool.start", "c-input", kind: "test")
        await crew.step()
        XCTAssertEqual(Set(ids()), ["lead", "c-input"])
        XCTAssertEqual(crew.items.first { $0.id.hasSuffix("/lead") }?.state, .idle)
        XCTAssertEqual(crew.items.first { $0.id.hasSuffix("/lead") }?.identity.name, "Atlas")
    }

    func testHelperNeverShows() async throws {
        try emit("prompt", "scout")
        await crew.step()
        XCTAssertTrue(crew.items.isEmpty)
        XCTAssertFalse(crew.isActive)
    }

    func testShowLeadWhenIdleKeepsLeadsAfterTheHold() async throws {
        crew.showLeadWhenIdle = true
        try emit("turn.end", "lead")
        try emit("turn.end", "pm")
        await crew.step()
        await advance(10)
        await advance(120)
        XCTAssertFalse(crew.isActive)
        XCTAssertEqual(ids(), ["lead"])
        XCTAssertEqual(crew.items.first?.state, .idle)
    }

    func testShowLeadWhenIdleTurnedOnLaterPublishesAtOnce() async throws {
        try emit("turn.end", "lead")
        await crew.step()
        await advance(10)
        await advance(120)
        XCTAssertTrue(crew.items.isEmpty)
        crew.showLeadWhenIdle = true
        XCTAssertEqual(ids(), ["lead"])
        crew.showLeadWhenIdle = false
        XCTAssertTrue(crew.items.isEmpty)
    }

    func testRailComesBackOnTheNextEvent() async throws {
        try emit("turn.end", "lead")
        await crew.step()
        await advance(200)
        XCTAssertTrue(crew.items.isEmpty)
        try emit("prompt", "lead")
        await crew.step()
        XCTAssertTrue(crew.isActive)
        XCTAssertEqual(ids(), ["lead"])
    }

    func testNeedsYouForWaitingAndError() async throws {
        try emit("prompt", "lead")
        await crew.step()
        XCTAssertFalse(crew.needsYou)
        try emit("needs.input", "pm")
        await crew.step()
        XCTAssertTrue(crew.needsYou)
        try emit("prompt", "pm")
        await crew.step()
        XCTAssertFalse(crew.needsYou)
        try emit("turn.fail", "pm")
        await crew.step()
        XCTAssertTrue(crew.needsYou)
    }

    func testOldHistoryAtLaunchDoesNotShowTheRail() async throws {
        try emit("tool.start", "lead", kind: "test")
        clock = clock.addingTimeInterval(7 * 3600)
        await crew.step()
        XCTAssertFalse(crew.isActive)
        XCTAssertTrue(crew.items.isEmpty)
    }

    // MARK: STOP

    func testStopAllWritesTheStopFile() throws {
        crew.stopAll()
        let text = try String(contentsOf: home.appendingPathComponent("STOP"), encoding: .utf8)
        XCTAssertEqual(text, "stopped 2026-11-27T14:00:00.000Z app\n")
    }

    func testStopFilePutsEveryAgentToSleepOnTheNextStep() async throws {
        crew.showLeadWhenIdle = true
        try emit("tool.start", "lead", kind: "test")
        try emit("prompt", "pm")
        await crew.step()
        XCTAssertEqual(crew.items.first { $0.id.hasSuffix("/lead") }?.state, .working)
        crew.stopAll()
        await advance(1)
        XCTAssertEqual(crew.items.map(\.state), [.asleep])
    }

    func testStopAllCreatesTheFolder() throws {
        let missing = home.appendingPathComponent("nested/crew")
        let other = CrewAgents(crewHome: missing, now: { Date() })
        other.stopAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: missing.appendingPathComponent("STOP").path))
    }

    // MARK: Lifecycle and snapshots

    func testStopClearsEverything() async throws {
        try emit("prompt", "lead")
        await crew.step()
        XCTAssertFalse(crew.items.isEmpty)
        crew.stop()
        XCTAssertTrue(crew.items.isEmpty)
        XCTAssertFalse(crew.isActive)
        XCTAssertFalse(crew.isAvailable)
    }

    func testRestartAfterStopReplaysRecentHistory() async throws {
        try emit("prompt", "lead")
        try emit("tool.start", "c-input", kind: "test")
        await crew.step()
        crew.stop()
        // No new event after the stop: a restart must still show both agents.
        await crew.step()
        XCTAssertEqual(Set(ids()), ["lead", "c-input"])
    }

    func testStepGivesTheMainActorBackWhileItReadsFiles() async throws {
        try emit("prompt", "lead")
        let pass = Task { await crew.step() }
        await Task.yield()
        // The step runs first. It must wait for the file reads off the main actor,
        // so this line runs before the step applies anything.
        XCTAssertTrue(crew.items.isEmpty, "step() read the files on the main actor")
        await pass.value
        XCTAssertEqual(ids(), ["lead"])
    }

    func testSeedForSnapshot() {
        let item = AgentRailItem(
            id: "/p/lead", identity: AgentFaceIdentity(name: "Atlas", role: .lead), state: .waiting)
        crew.seedForSnapshot([item])
        XCTAssertEqual(crew.items, [item])
        XCTAssertTrue(crew.isActive)
        XCTAssertTrue(crew.isAvailable)
        XCTAssertTrue(crew.needsYou)
    }
}
