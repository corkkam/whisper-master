import XCTest
@testable import WhisperMaster

/// `CrewRuns`: what `crew run` gets, what a result turns into, and the question loop.
/// A stub launcher stands in for the process, so no test starts `crew` or `claude`.
@MainActor
final class CrewRunsTests: XCTestCase {
    /// What the stub saw: the arguments, the folder, and the task file's text.
    private actor Calls {
        var seen: [(arguments: [String], folder: String, task: String)] = []
        func add(_ arguments: [String], _ folder: String, _ task: String) {
            seen.append((arguments, folder, task))
        }
    }

    private var crewHome: URL!
    private var project: URL!

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crew-runs-\(UUID().uuidString)")
        crewHome = root.appendingPathComponent("crew-home")
        project = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: crewHome.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        let shim = crewHome.appendingPathComponent("bin/crew")
        try "#!/bin/sh\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: crewHome.deletingLastPathComponent())
    }

    /// Runs answer from `outputs` in order and record what they were given.
    private func makeRuns(_ outputs: [String], calls: Calls) -> CrewRuns {
        let queue = OutputQueue(outputs)
        return CrewRuns(crewHome: crewHome, home: crewHome) { arguments, folder, _ in
            let file = arguments[arguments.firstIndex(of: "--file")! + 1]
            let task = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            await calls.add(arguments, folder, task)
            return CrewRuns.Output(status: 0, stdout: await queue.next(), stderr: "")
        }
    }

    private actor OutputQueue {
        var items: [String]
        init(_ items: [String]) { self.items = items }
        func next() -> String { items.isEmpty ? "" : items.removeFirst() }
    }

    private func writePlan(task: String, question: String) throws {
        let folder = project.appendingPathComponent(".crew/tasks/\(task)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "## Goal\nShorter headline.\n\n## Open question\n\(question)\n\n## Steps\n1. Edit.\n"
            .write(to: folder.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
    }

    // MARK: Pure parts

    func testResultLineIsReadAndRemoved() {
        let r = CrewResult(output: "Plan ready.\n\n{\"crew_result\": \"needs_approval\", \"task_id\": \"t-1\", \"pr\": null}\n")
        XCTAssertEqual(r.word, "needs_approval")
        XCTAssertEqual(r.taskID, "t-1")
        XCTAssertEqual(r.text, "Plan ready.")
        XCTAssertNil(CrewResult(output: "no line").word)
    }

    func testPlanSections() {
        let plan = "## Goal\nX\n\n## Open question\nWhich line?\n\n## Steps\n1. Y\n"
        XCTAssertEqual(CrewRuns.section("Open question", inPlan: plan), "Which line?")
        XCTAssertEqual(CrewRuns.section("Goal", inPlan: plan), "X")
        XCTAssertNil(CrewRuns.section("Open question", inPlan: "## Open question\nNone.\n## Steps\n"))
        XCTAssertNil(CrewRuns.section("Open question", inPlan: "## Goal\nX\n"))
    }

    func testAFastPathPlanAsksToApproveItsGoal() async throws {
        let folder = project.appendingPathComponent(".crew/tasks/t-5")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "## Goal\nAppend one line.\n\n## Route\nFast path.\n"
            .write(to: folder.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
        let runs = makeRuns(["I stopped.\n{\"crew_result\": \"needs_approval\", \"task_id\": \"t-5\"}"], calls: Calls())
        XCTAssertNil(runs.start("Append one line", project: project.path))
        await runs.job?.value
        guard case .choice(let choice)? = runs.ask else { return XCTFail("no card") }
        XCTAssertEqual(choice.primary?.text, "Approve this plan?\nAppend one line.")
    }

    func testFirstParagraphDropsTerminalCommands() {
        let text = "Atlas stopped at the gate.\ncrew run --task-id t-1 --approved \"x\"\n\nMore."
        XCTAssertEqual(CrewRuns.firstParagraph(text), "Atlas stopped at the gate.")
    }

    func testTaskGoesInAFileAndApprovalAddsTheFlags() {
        XCTAssertEqual(CrewRuns.arguments(shim: "/c", taskFile: "/f", taskID: nil),
                       ["/c", "run", "--quiet", "--file", "/f"])
        XCTAssertEqual(CrewRuns.arguments(shim: "/c", taskFile: "/f", taskID: "t-1"),
                       ["/c", "run", "--quiet", "--file", "/f", "--task-id", "t-1", "--approved"])
    }

    func testEnvironmentIsAllowlisted() {
        let home = URL(fileURLWithPath: "/Users/x")
        let env = CrewRuns.environment(
            home: home, claude: URL(fileURLWithPath: "/Users/x/.local/bin/claude"),
            inherited: ["ANTHROPIC_API_KEY": "k", "CLAUDECODE": "1", "USER": "x", "LANG": "en_GB.UTF-8"])
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertEqual(env["USER"], "x")
        XCTAssertEqual(env["CREW_CLAUDE_BIN"], "/Users/x/.local/bin/claude")
        XCTAssertTrue(env["PATH"]!.hasPrefix("/Users/x/.crew/bin:/Users/x/.local/bin:"))
    }

    func testScratchProjectsAreSkipped() {
        XCTAssertTrue(CrewAgents.isScratch("/private/var/folders/lq/x/T/crew-smoke.1/repo"))
        XCTAssertFalse(CrewAgents.isScratch("/Users/x/code/typing-sucks"))
    }

    // MARK: The question loop

    func testNeedsApprovalRaisesTheCardAndApproveContinues() async throws {
        try writePlan(task: "t-9", question: "Which headline?")
        let calls = Calls()
        let runs = makeRuns([
            "Plan ready.\n{\"crew_result\": \"needs_approval\", \"task_id\": \"t-9\"}",
            "Done: headline changed.\n{\"crew_result\": \"changed\", \"task_id\": \"t-9\"}",
        ], calls: calls)
        var shown: [String] = []
        runs.onResult = { _, text, _ in shown.append(text) }

        XCTAssertNil(runs.start("Shorten the hero headline", project: project.path))
        await runs.job?.value
        guard case .choice(let choice)? = runs.ask else { return XCTFail("no card") }
        XCTAssertEqual(choice.primary?.text, "Which headline?")
        XCTAssertEqual(choice.primary?.options, [CrewRuns.approve, CrewRuns.notNow])
        XCTAssertEqual(runs.pending?.taskID, "t-9")

        runs.answer(choice, selected: [CrewRuns.approve])
        await runs.job?.value
        let seen = await calls.seen
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0].folder, project.path)
        XCTAssertEqual(seen[0].task, "Shorten the hero headline")
        XCTAssertEqual(Array(seen[1].arguments.suffix(3)), ["--task-id", "t-9", "--approved"])
        XCTAssertTrue(seen[1].task.contains("approved"))
        XCTAssertNil(runs.ask)
        XCTAssertNil(runs.pending)
        XCTAssertEqual(shown, ["Done: headline changed."])
    }

    func testASpokenTaskWhileWaitingIsTheAnswer() async throws {
        let calls = Calls()
        let runs = makeRuns([
            "{\"crew_result\": \"needs_approval\", \"task_id\": \"t-2\"}",
            "{\"crew_result\": \"changed\", \"task_id\": \"t-2\"}",
        ], calls: calls)
        XCTAssertNil(runs.start("Pick a headline", project: project.path))
        await runs.job?.value
        XCTAssertNotNil(runs.ask)

        XCTAssertNil(runs.start("Use the second one", project: "/somewhere/else"))
        await runs.job?.value
        let seen = await calls.seen
        XCTAssertEqual(seen[1].folder, project.path, "the answer goes to the waiting task's project")
        XCTAssertTrue(seen[1].task.hasPrefix("Pick a headline"))
        XCTAssertTrue(seen[1].task.contains("The owner's answer to the open question: Use the second one"))
        XCTAssertTrue(seen[1].arguments.contains("--approved"))
    }

    func testNotNowDropsTheTaskAndSkipKeepsIt() async throws {
        let runs = makeRuns(["{\"crew_result\": \"needs_approval\", \"task_id\": \"t-3\"}"], calls: Calls())
        XCTAssertNil(runs.start("Task", project: project.path))
        await runs.job?.value
        guard case .choice(let choice)? = runs.ask else { return XCTFail("no card") }

        runs.answer(choice, selected: [])
        XCTAssertNil(runs.ask)
        XCTAssertNotNil(runs.pending, "Skip keeps the task waiting")
        runs.showLast()
        XCTAssertEqual(runs.ask, .choice(choice), "a click on a face shows the card again")

        runs.answer(choice, selected: [CrewRuns.notNow])
        XCTAssertNil(runs.ask)
        XCTAssertNil(runs.pending)
    }

    func testOneRunAtATime() async throws {
        let runs = makeRuns(["{\"crew_result\": \"no_change\", \"task_id\": \"t-4\"}"], calls: Calls())
        XCTAssertNil(runs.start("First", project: project.path))
        XCTAssertEqual(runs.start("Second", project: project.path), CrewRuns.busy)
        await runs.job?.value
        XCTAssertNil(runs.running)
    }

    func testNoTextShowsTheCrewLine() {
        let line = CrewRuns.failureLine(.init(status: 4, stdout: "", stderr: "crew: STOP file is set\n"))
        XCTAssertEqual(line, "The Crew stopped: STOP file is set")
    }

    func testNoShimNoRun() {
        let runs = CrewRuns(crewHome: crewHome.appendingPathComponent("missing"), home: crewHome) { _, _, _ in
            XCTFail("must not launch")
            return .init(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(runs.start("Task", project: project.path), CrewRuns.notInstalled)
    }

    // MARK: The hand-off

    func testDelegateIsOfferedForTheCrewWithItsConsent() {
        let offered = { (consented: Bool, local: Bool) in
            DelegateToolCatalog.offered(kunai: false, shed: false, deskFolder: nil, consented: false,
                                        staysLocal: local, crewProject: "/p", crewConsented: consented)
                .map(\.name)
        }
        XCTAssertEqual(offered(true, false), ["delegate_task"])
        XCTAssertEqual(offered(false, false), [])
        XCTAssertEqual(offered(true, true), [], "a capture kept on this Mac never goes to the Crew")
    }
}
