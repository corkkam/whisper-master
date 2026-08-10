import XCTest

@testable import WhisperMaster

/// The finish banner holds one line, and Claude writes markdown. These pin the
/// presentation that turned a reply opening with a code fence into a title of
/// literally ``` on the band.
final class AgentReplyLineTests: XCTestCase {

    func testAReplyOpeningWithACodeFenceShowsItsProseNotTheFence() {
        let raw = """
            ```swift
            let x = 1
            ```
            Cleared the build and rewrote the assertion.
            """
        XCTAssertEqual(
            AgentReplyLine.compact(raw), "Cleared the build and rewrote the assertion.")
    }

    func testPlainProseIsUntouched() {
        XCTAssertEqual(AgentReplyLine.compact("Done. All tests pass."), "Done. All tests pass.")
    }

    func testMarkdownChromeIsStrippedButTheWordsAreNot() {
        XCTAssertEqual(AgentReplyLine.compact("## Fixed the `route` bug"), "Fixed the route bug")
        XCTAssertEqual(AgentReplyLine.compact("- **First**: renamed it"), "First: renamed it")
    }

    func testAReplyThatIsOnlyCodeYieldsNilSoTheCallerSaysFinished() {
        let raw = """
            ```
            swift build
            ```
            """
        XCTAssertNil(AgentReplyLine.compact(raw))
    }

    func testLeadingBlankLinesAreSkipped() {
        XCTAssertEqual(AgentReplyLine.compact("\n\n  \nShipped it."), "Shipped it.")
    }

    // MARK: The working caption

    func testTheWorkingCaptionNamesTheToolCallInProgress() throws {
        var log = AgentTurnLog()
        try log.apply(decode(
            #"{"seq":1,"t":"assistant","blocks":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/x/UI/NotchGlow.swift"}}]}"#))
        XCTAssertEqual(log.currentActivity, "Editing UI/NotchGlow.swift")
    }

    func testAFinishedCallStillBeatsABareRepoName() throws {
        var log = AgentTurnLog()
        try log.apply(decode(
            #"{"seq":1,"t":"assistant","blocks":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}"#))
        try log.apply(decode(#"{"seq":2,"t":"tool_result","tool_use_id":"t1"}"#))
        XCTAssertEqual(log.currentActivity, "Running swift test")
    }

    func testTheInFlightCallOutranksTheFinishedOne() throws {
        var log = AgentTurnLog()
        try log.apply(decode(
            #"{"seq":1,"t":"assistant","blocks":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"old"}}]}"#))
        try log.apply(decode(#"{"seq":2,"t":"tool_result","tool_use_id":"t1"}"#))
        try log.apply(decode(
            #"{"seq":3,"t":"assistant","blocks":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/x/a/b.swift"}}]}"#))
        XCTAssertEqual(log.currentActivity, "Reading a/b.swift")
    }

    func testACompoundShellCommandIsTrimmedToItsLeadingCommand() {
        // Claude opens most turns with a git-status combo; the whole compound
        // string in a one-line caption is noise, and the trim is visible, never
        // silent.
        XCTAssertEqual(
            AgentTurnLog.presentActivity(
                name: "Bash", detail: "Run  git status --short; echo \"== recent\"; git log"),
            "Running git status --short …")
        XCTAssertEqual(
            AgentTurnLog.presentActivity(name: "Bash", detail: "Run  swift build && swift test"),
            "Running swift build …")
        XCTAssertEqual(
            AgentTurnLog.presentActivity(name: "Bash", detail: "Run  swift test"),
            "Running swift test")
    }

    func testNoToolsYetMeansNoActivitySoTheRowShowsTheRepo() {
        XCTAssertNil(AgentTurnLog().currentActivity)
    }

    private func decode(_ json: String) throws -> KunaiWire.Event {
        try JSONDecoder().decode(KunaiWire.Event.self, from: Data(json.utf8))
    }
}

/// The expanded band's document: prose stays prose, code stays code, and the
/// height math is decided before layout (the standing band rule).
final class AgentReplyDocumentTests: XCTestCase {

    func testProseAndCodeSplitAtTheFences() {
        let doc = AgentReplyDocument.parse(
            "Fixed it.\n```swift\nlet x = 1\nlet y = 2\n```\nAll tests pass.")
        XCTAssertEqual(
            doc.blocks,
            [.prose("Fixed it."), .code("let x = 1\nlet y = 2"), .prose("All tests pass.")])
    }

    func testAHeadingLeadsItsListRatherThanFlatteningIntoIt() {
        let doc = AgentReplyDocument.parse("## What changed\n- kept the dash")
        XCTAssertEqual(doc.blocks, [.heading("What changed"), .prose("- kept the dash")])
    }

    func testAnUnclosedFenceStillShowsItsCode() {
        let doc = AgentReplyDocument.parse("Here:\n```\nswift build")
        XCTAssertEqual(doc.blocks, [.prose("Here:"), .code("swift build")])
    }

    func testAnEmptyReplyMakesAnEmptyDocument() {
        XCTAssertTrue(AgentReplyDocument.parse("  \n ").isEmpty)
    }

    func testAPipeTableBecomesARealTableNotLiteralPipes() {
        // The `| tool | path | |---|---|` garbage that kept being reported: raw
        // markdown tables on the band.
        let doc = AgentReplyDocument.parse(
            "| tool | path |\n|---|---|\n| swift | /usr/bin/swift |\n| xcodegen | /opt/homebrew/bin/xcodegen |")
        XCTAssertEqual(
            doc.blocks,
            [.table(
                header: ["tool", "path"],
                rows: [["swift", "/usr/bin/swift"], ["xcodegen", "/opt/homebrew/bin/xcodegen"]])])
    }

    func testATableWithNoSeparatorHasNoHeader() {
        let doc = AgentReplyDocument.parse("| a | b |\n| c | d |")
        XCTAssertEqual(doc.blocks, [.table(header: [], rows: [["a", "b"], ["c", "d"]])])
    }

    func testAHeadingIsItsOwnBlockWithItsHashesGone() {
        let doc = AgentReplyDocument.parse("## Toolchain\nEverything installed.")
        XCTAssertEqual(doc.blocks, [.heading("Toolchain"), .prose("Everything installed.")])
    }

    func testProseTableAndCodeInterleaveInOrder() {
        let doc = AgentReplyDocument.parse(
            "Intro.\n| a | b |\n|---|---|\n| 1 | 2 |\n```\nls\n```\nDone.")
        XCTAssertEqual(doc.blocks.count, 4)
        XCTAssertEqual(doc.blocks.first, .prose("Intro."))
        XCTAssertEqual(doc.blocks.last, .prose("Done."))
    }
}

/// Click-to-expand and the Settings default, on the controller.
@MainActor
final class AgentReplyExpansionTests: XCTestCase {

    private func revealed() -> AgentSurfaceController {
        let controller = AgentSurfaceController(candidates: [])
        controller.seedReplyForSnapshot(
            session: AgentSession(id: "s1", repo: "r", state: .idle),
            reply: "Done.", duration: 5)
        return controller
    }

    func testClickingExpandsAndPinsSoItCannotVanishUnderTheReader() {
        let controller = revealed()
        controller.toggleReplyExpansion()
        XCTAssertTrue(controller.replyExpanded)
        let muchLater = Date().addingTimeInterval(AgentSurfaceController.expandedRevealHold * 10)
        XCTAssertFalse(controller.revealHasExpired(now: muchLater))
    }

    func testCollapsingRestartsTheRetractClock() {
        let controller = revealed()
        controller.toggleReplyExpansion()
        controller.toggleReplyExpansion()
        XCTAssertFalse(controller.replyExpanded)
        XCTAssertFalse(controller.revealHasExpired(now: Date()))
        let later = Date().addingTimeInterval(AgentSurfaceController.revealHold + 1)
        XCTAssertTrue(controller.revealHasExpired(now: later))
    }

    func testTheRawReplySurvivesForExpansion() {
        // The banner shows a compacted line; expanding must go back to the source,
        // not inflate the truncated line.
        let controller = AgentSurfaceController(candidates: [])
        controller.seedReplyForSnapshot(
            session: AgentSession(id: "s1", repo: "r", state: .idle),
            reply: "```\ncode\n```\nProse line.", duration: 5)
        XCTAssertEqual(controller.lastReply, "Prose line.")
        XCTAssertEqual(controller.lastReplyRaw, "```\ncode\n```\nProse line.")
    }
}

/// How the expanded band reads a reply: one sentence as the verdict, then words
/// and data in their own columns.
final class AgentReplySplitTests: XCTestCase {

    func testTheVerdictIsOneSentenceAndTheRestRejoinsTheBody() {
        // A model often answers in a single long paragraph. Setting all of it in
        // display type truncated with an ellipsis, and the headline is the one line
        // on this surface that must never be cut.
        let doc = AgentReplyDocument.parse(
            "Too vague for me to guess well. \"Things\" could be files, directories, "
                + "tools, branches, issues, or capabilities.")
        let split = doc.split()
        XCTAssertEqual(split.headline, "Too vague for me to guess well.")
        XCTAssertEqual(split.words.count, 1)
        XCTAssertEqual(
            split.words.first?.text,
            "\"Things\" could be files, directories, tools, branches, issues, or capabilities.")
    }

    func testAVersionNumberDoesNotEndTheVerdict() {
        // A terminator only ends a sentence when whitespace follows it, or
        // "parakeet-tdt-0.6b-v3" would become the whole headline.
        let doc = AgentReplyDocument.parse("Loaded parakeet-tdt-0.6b-v3 and warmed it. Ready.")
        XCTAssertEqual(doc.split().headline, "Loaded parakeet-tdt-0.6b-v3 and warmed it.")
    }

    func testAReplyOpeningWithCodeStillGetsAVerdictFromItsProse() {
        // The verdict is the first prose *anywhere*, not only the first block. A
        // reply that leads with a fence and explains itself underneath used to leave
        // the headline slot empty and orphan the explanation in a column beside the
        // fence, which reduced the whole surface to two small things in a wide band.
        let doc = AgentReplyDocument.parse("```\nCLAUDE.md README.md\n```\n\n11 files.")
        let split = doc.split()
        XCTAssertEqual(split.headline, "11 files.")
        XCTAssertEqual(split.data.count, 1)
        XCTAssertTrue(split.words.isEmpty)
    }

    func testAReplyWithNoProseAtAllHasNoVerdict() {
        // Inventing one from the fence would put a shell command in display type.
        let doc = AgentReplyDocument.parse("```\nswift build\n```")
        XCTAssertNil(doc.split().headline)
    }

    func testShortOutputDoesNotEarnTheConsoleWidth() {
        // Two lines of narrow output do not justify a thousand points of black.
        let narrow = AgentReplyDocument.parse("Done.\n\n```\nok\n```")
        XCTAssertFalse(
            NotchAgentReplyExpanded.Layout.wantsConsole(
                document: narrow, toolCount: 0, changedCount: 0))
        let wide = AgentReplyDocument.parse(
            "Done.\n\n```\n" + String(repeating: "x", count: 90) + "\n```")
        XCTAssertTrue(
            NotchAgentReplyExpanded.Layout.wantsConsole(
                document: wide, toolCount: 0, changedCount: 0))
    }

    func testAHeadingTravelsWithTheDataItHeads() {
        // Splitting purely by kind stranded the caption in the words column while
        // the table it captioned sat in the other one.
        let doc = AgentReplyDocument.parse(
            "Ran both.\n\n## Toolchain\n\n| tool | version |\n|---|---|\n| swift | 6.3 |\n\n"
                + "## Notes\n\nNothing else changed.")
        let split = doc.split()
        XCTAssertEqual(split.data.count, 2)  // the heading and its table
        if case .heading(let text) = split.data.first {
            XCTAssertEqual(text, "Toolchain")
        } else {
            XCTFail("the heading above a table belongs to the data column")
        }
        // A heading above prose stays with the prose.
        XCTAssertTrue(split.words.contains { $0.text == "Notes" })
    }
}
