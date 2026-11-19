import XCTest

@testable import WhisperMaster

/// The tools that act on this Mac. Two rules carry the safety: nothing opens without
/// the card (or a standing grant the user gave for that exact app), and nothing is
/// typed into another app at all — a draft only reaches the band, and the tap on the
/// band is the consent.
@MainActor
final class DeviceToolRunnerTests: XCTestCase {
    private final class Recorder {
        var opened: [URL] = []
        var cards: [PendingApproval] = []
    }

    private let figma = InstalledApp(name: "Figma", url: URL(fileURLWithPath: "/Applications/Figma.app"))
    private let mail = SelectionReader.FrontApp(bundleID: "com.apple.mail", name: "Mail", pid: 401)
    private let terminal = SelectionReader.FrontApp(bundleID: "com.apple.Terminal", name: "Terminal", pid: 402)

    private func emptyStore() -> ConnectorInstanceStore {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        return store
    }

    private func selection(_ text: String = "The quarterly numbers are in and they look good.") -> SelectionContext {
        SelectionContext(appName: "Mail", windowTitle: nil, text: text,
                         wasCut: false, originalLength: text.count)
    }

    private func runner(answer: ApprovalOutcome = .allowedOnce,
                        recorder: Recorder,
                        store: ConnectorInstanceStore? = nil,
                        taint: Taint? = nil,
                        keyDown: SelectionReader.FrontApp? = nil,
                        frontNow: SelectionReader.FrontApp? = nil,
                        selection: SelectionContext? = nil) -> DeviceToolRunner {
        let apps = [figma]
        return DeviceToolRunner(
            store: store ?? emptyStore(),
            requestApproval: { approval in recorder.cards.append(approval); return answer },
            environment: DeviceToolRunner.Environment(
                installedApp: { InstalledApps.match($0, in: apps) },
                openApp: { recorder.opened.append($0); return true },
                openURL: { recorder.opened.append($0); return true },
                frontApp: { frontNow ?? keyDown }),
            taint: taint ?? Taint(),
            frontApp: keyDown,
            selection: selection)
    }

    private func call(_ tool: String, _ arguments: [String: String]) -> ToolCall {
        ToolCall(tool: tool, arguments: arguments)
    }

    // MARK: - open_app

    func testOpenAppOpensOnlyAnInstalledApp() async {
        let recorder = Recorder()
        let (result, effect) = await runner(recorder: recorder)
            .run(call("open_app", ["app": "Photoshop"]))
        XCTAssertFalse(result.ok)
        XCTAssertNil(effect)
        XCTAssertTrue(recorder.cards.isEmpty, "no card for an app that is not there")
        XCTAssertTrue(recorder.opened.isEmpty)
    }

    func testOpenAppAsksOnTheCardForThisMac() async {
        let recorder = Recorder()
        let (result, effect) = await runner(recorder: recorder)
            .run(call("open_app", ["app": "figma"]))

        let card = try? XCTUnwrap(recorder.cards.first)
        XCTAssertEqual(card?.target, "Figma", "the card names the app as installed, not as heard")
        XCTAssertEqual(card?.instanceID, DeviceToolCatalog.thisMacID)
        XCTAssertEqual(card?.instanceLabel, DeviceToolCatalog.thisMacLabel)
        XCTAssertEqual(card?.offersAlways, true)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.authorization, .allowedOnce)
        XCTAssertEqual(effect, .openedApp(name: "Figma"))
        XCTAssertEqual(recorder.opened, [figma.url])
    }

    func testAlwaysStoresAGrantForThisMacAndTheNextOpenAsksNothing() async {
        let recorder = Recorder()
        let store = emptyStore()
        _ = await runner(answer: .allowedAlways, recorder: recorder, store: store)
            .run(call("open_app", ["app": "Figma"]))
        XCTAssertEqual(store.grants.map(\.id),
                       [Grant(tool: "open_app", instanceID: DeviceToolCatalog.thisMacID, target: "Figma").id])

        let again = Recorder()
        let (result, _) = await runner(answer: .denied, recorder: again, store: store)
            .run(call("open_app", ["app": "Figma"]))
        XCTAssertTrue(again.cards.isEmpty, "a standing grant answers for the same app")
        XCTAssertEqual(result.authorization, .standingGrant)
        XCTAssertEqual(again.opened, [figma.url])
    }

    /// The taint rule, unchanged for the new route: after untrusted text, the grant
    /// does not answer and the card offers no Always.
    func testATaintedRunAsksEvenWithAGrant() async {
        let store = emptyStore()
        store.addGrant(Grant(tool: "open_app", instanceID: DeviceToolCatalog.thisMacID, target: "Figma"))
        let taint = Taint()
        taint.isSet = true
        let recorder = Recorder()
        _ = await runner(answer: .allowedAlways, recorder: recorder, store: store, taint: taint)
            .run(call("open_app", ["app": "Figma"]))
        XCTAssertEqual(recorder.cards.count, 1)
        XCTAssertEqual(recorder.cards.first?.offersAlways, false)
        XCTAssertNotNil(recorder.cards.first?.readWarning)
        XCTAssertEqual(store.grants.count, 1, "an Always in a tainted run stores nothing")
    }

    func testADeclinedCardOpensNothing() async {
        let recorder = Recorder()
        let (result, effect) = await runner(answer: .denied, recorder: recorder)
            .run(call("open_app", ["app": "Figma"]))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.authorization, .denied)
        XCTAssertNil(effect)
        XCTAssertTrue(recorder.opened.isEmpty)
    }

    // MARK: - open_url

    func testOpenURLOpensOnlyHTTPAndHTTPS() async {
        for link in ["file:///etc/passwd", "javascript:alert(1)", "ftp://example.com",
                     "x-apple.systempreferences:com.apple.preference.security", "not a link"] {
            let recorder = Recorder()
            let (result, _) = await runner(recorder: recorder).run(call("open_url", ["url": link]))
            XCTAssertFalse(result.ok, link)
            XCTAssertTrue(recorder.cards.isEmpty, "no card for \(link)")
            XCTAssertTrue(recorder.opened.isEmpty, link)
        }
    }

    /// Even a grant on file does not skip it, and Always is never offered or kept.
    func testOpenURLRaisesTheCardEveryTimeWithNoAlways() async {
        let store = emptyStore()
        store.addGrant(Grant(tool: "open_url", instanceID: DeviceToolCatalog.thisMacID,
                             target: "https://github.com/settings"))
        let recorder = Recorder()
        let (result, effect) = await runner(answer: .allowedAlways, recorder: recorder, store: store)
            .run(call("open_url", ["url": "https://github.com/settings"]))

        XCTAssertEqual(recorder.cards.count, 1)
        XCTAssertEqual(recorder.cards.first?.offersAlways, false)
        XCTAssertNil(recorder.cards.first?.readWarning, "an untainted run carries no warning")
        XCTAssertEqual(recorder.cards.first?.arguments["url"], "https://github.com/settings",
                       "the card carries the full link")
        XCTAssertEqual(result.authorization, .allowedOnce)
        XCTAssertEqual(effect, .openedURL(host: "github.com"))
        XCTAssertEqual(store.grants.count, 1, "no grant is added for a link")
    }

    func testABareDomainFromTheModelIsOpenedOverHTTPS() async {
        let recorder = Recorder()
        _ = await runner(recorder: recorder).run(call("open_url", ["url": "github.com"]))
        XCTAssertEqual(recorder.opened, [URL(string: "https://github.com")!])
    }

    func testATaintedRunRefusesALinkWithAQueryOrFragment() async {
        for link in ["https://evil.example/collect?d=secret", "https://evil.example/#secret"] {
            let taint = Taint()
            taint.isSet = true
            let recorder = Recorder()
            let (result, _) = await runner(recorder: recorder, taint: taint)
                .run(call("open_url", ["url": link]))
            XCTAssertFalse(result.ok, link)
            XCTAssertTrue(recorder.cards.isEmpty, "refused before any card: \(link)")
        }
    }

    func testATaintedRunMayStillOpenAPlainLinkBehindTheCard() async {
        let taint = Taint()
        taint.isSet = true
        let recorder = Recorder()
        let (result, _) = await runner(recorder: recorder, taint: taint)
            .run(call("open_url", ["url": "https://example.com/docs"]))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(recorder.cards.count, 1)
        XCTAssertNotNil(recorder.cards.first?.readWarning)
    }

    func testALinkThatHidesItsHostOrIsTooLongIsRefused() async {
        let long = "https://example.com/" + String(repeating: "a", count: DeviceToolCatalog.maxURLLength)
        for link in ["https://github.com@evil.example/", long] {
            let recorder = Recorder()
            let (result, _) = await runner(recorder: recorder).run(call("open_url", ["url": link]))
            XCTAssertFalse(result.ok)
            XCTAssertTrue(recorder.cards.isEmpty)
        }
    }

    // MARK: - Drafts

    func testReplaceSelectionStagesADraftAndTypesNothing() async {
        let recorder = Recorder()
        let (result, effect) = await runner(recorder: recorder, keyDown: mail, selection: selection())
            .run(call("replace_selection", ["text": "Numbers are in. They look good."]))
        XCTAssertTrue(result.ok)
        XCTAssertTrue(recorder.cards.isEmpty, "the band is the consent, not the card")
        guard case .draftStaged(let draft)? = effect else { return XCTFail("no draft") }
        XCTAssertEqual(draft.kind, .replaceSelection)
        XCTAssertEqual(draft.text, "Numbers are in. They look good.")
        XCTAssertEqual(draft.app, mail)
        XCTAssertNil(draft.copyOnlyReason)
        XCTAssertEqual(draft.actionTitle, "Replace")
    }

    func testReplaceSelectionNeedsASelection() async {
        let (result, effect) = await runner(recorder: Recorder(), keyDown: mail)
            .run(call("replace_selection", ["text": "Shorter."]))
        XCTAssertFalse(result.ok)
        XCTAssertNil(effect)
    }

    func testInsertTextNeedsTheAppFromKeyDown() async {
        let (result, effect) = await runner(recorder: Recorder())
            .run(call("insert_text", ["text": "On my way."]))
        XCTAssertFalse(result.ok)
        XCTAssertNil(effect)
    }

    func testFocusMovedAfterKeyDownMakesTheDraftCopyOnly() async {
        let slack = SelectionReader.FrontApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", pid: 777)
        let (_, effect) = await runner(recorder: Recorder(), keyDown: mail, frontNow: slack)
            .run(call("insert_text", ["text": "On my way."]))
        guard case .draftStaged(let draft)? = effect else { return XCTFail("no draft") }
        XCTAssertEqual(draft.copyOnlyReason, AgentDraft.focusMoved)
        XCTAssertEqual(draft.actionTitle, "Copy")
    }

    func testTextReadFromAnAccountMakesTheDraftCopyOnly() async {
        let taint = Taint()
        taint.isSet = true
        taint.outsideSelection = true
        let (_, effect) = await runner(recorder: Recorder(), taint: taint, keyDown: mail)
            .run(call("insert_text", ["text": "Sure, wire it today."]))
        guard case .draftStaged(let draft)? = effect else { return XCTFail("no draft") }
        XCTAssertEqual(draft.copyOnlyReason, AgentDraft.afterReading)
    }

    /// "Make this shorter" reads the selection it rewrites. That read alone must not
    /// take Replace away, or the feature could never type anything.
    func testReadingTheSelectionItselfKeepsReplace() async {
        let taint = Taint()
        taint.isSet = true
        let (_, effect) = await runner(recorder: Recorder(), taint: taint,
                                       keyDown: mail, selection: selection())
            .run(call("replace_selection", ["text": "Numbers look good."]))
        guard case .draftStaged(let draft)? = effect else { return XCTFail("no draft") }
        XCTAssertNil(draft.copyOnlyReason)
    }

    func testATerminalLosesTrailingNewlines() async {
        let (_, effect) = await runner(recorder: Recorder(), keyDown: terminal)
            .run(call("insert_text", ["text": "git status\n\n"]))
        guard case .draftStaged(let draft)? = effect else { return XCTFail("no draft") }
        XCTAssertEqual(draft.text, "git status", "a trailing newline would run the command")
        XCTAssertNil(draft.copyOnlyReason)
    }

    func testATerminalRefusesAMultiLineInsert() async {
        let (_, effect) = await runner(recorder: Recorder(), keyDown: terminal)
            .run(call("insert_text", ["text": "cd repo\nrm -rf build"]))
        guard case .draftStaged(let draft)? = effect else { return XCTFail("no draft") }
        XCTAssertEqual(draft.copyOnlyReason, AgentDraft.multiLineInTerminal)
        XCTAssertEqual(draft.actionTitle, "Copy")
    }

    func testAnEmptyDraftIsRefused() async {
        let (result, effect) = await runner(recorder: Recorder(), keyDown: terminal)
            .run(call("insert_text", ["text": "\n\n"]))
        XCTAssertFalse(result.ok)
        XCTAssertNil(effect)
    }

    // MARK: - The route

    /// The new route needs no connector at all: a user who never connected anything
    /// still gets the card, and only an opened app counts as having acted.
    func testTheCardShowsWhenTheUserHasNoConnector() async {
        let recorder = Recorder()
        let notes = NotesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("device-\(UUID()).json"), load: false)
        let router = CommandToolRouter(
            local: LocalToolRunner(notes: notes),
            connectors: nil,
            device: runner(answer: .denied, recorder: recorder))

        let denied = await router.run(call("open_app", ["app": "Figma"]))
        XCTAssertEqual(recorder.cards.count, 1)
        XCTAssertEqual(recorder.cards.first?.instanceLabel, "This Mac")
        XCTAssertFalse(denied.ok)
        XCTAssertTrue(router.executed.isEmpty, "a declined card is not an action")
        XCTAssertFalse(router.didCreateSomething)
    }

    /// The wiring through the service: the model's draft comes back on the run, and
    /// the run counts as having acted, so the words are not also filed as a note.
    func testTheServiceHandsTheDraftBack() async {
        let notes = NotesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("device-\(UUID()).json"), load: false)
        var service = CommandAgentService(
            store: emptyStore(), notes: notes, approvals: ApprovalCoordinator(),
            connectorsAllowed: false, selection: selection())
        service.frontApp = mail
        service.device = DeviceToolRunner.Environment(
            installedApp: { _ in nil }, openApp: { _ in false }, openURL: { _ in false },
            frontApp: { [mail] in mail })
        let run = await service.run(
            "make this shorter",
            generate: ScriptedModel([
                #"{"tool":"read_selection","args":{}}"#,
                #"{"tool":"replace_selection","args":{"text":"Numbers look good."}}"#,
                #"{"answer":"Here is a shorter version."}"#,
            ]).generate)

        XCTAssertTrue(run.toolsOffered.contains("replace_selection"))
        XCTAssertEqual(run.draft?.text, "Numbers look good.")
        XCTAssertNil(run.draft?.copyOnlyReason)
        XCTAssertEqual(run.result?.createdSomething, true)
    }

    // MARK: - Review fixes

    /// B3: the selection read is exempt only for a Replace outside a terminal.
    func testAfterASelectionReadAnInsertOrATerminalIsCopyOnly() async {
        let taint = Taint()
        taint.isSet = true
        let (_, insert) = await runner(recorder: Recorder(), taint: taint, keyDown: mail)
            .run(call("insert_text", ["text": "Summary: numbers look good."]))
        guard case .draftStaged(let inserted)? = insert else { return XCTFail("no draft") }
        XCTAssertEqual(inserted.copyOnlyReason, AgentDraft.afterReadingSelection)

        let (_, replace) = await runner(recorder: Recorder(), taint: taint,
                                        keyDown: terminal, selection: selection("ls -la"))
            .run(call("replace_selection", ["text": "ls -lah"]))
        guard case .draftStaged(let replaced)? = replace else { return XCTFail("no draft") }
        XCTAssertEqual(replaced.copyOnlyReason, AgentDraft.afterReadingSelection)
    }

    /// B4: what the band cannot show, the tap must not type.
    func testHiddenCharactersMakeTheDraftCopyOnly() async {
        for text in ["clear\u{1B}[2J", "pay \u{202E}0001$", "ok\u{200B}go", "a\u{0}b", "line\u{85}two"] {
            let (_, effect) = await runner(recorder: Recorder(), keyDown: mail)
                .run(call("insert_text", ["text": text]))
            guard case .draftStaged(let draft)? = effect else { return XCTFail("no draft") }
            XCTAssertEqual(draft.copyOnlyReason, AgentDraft.hiddenCharacters, text.debugDescription)
        }
        for text in ["a\tb", "Hi Sam,\n\nThanks.\r\nDana"] {
            let (_, effect) = await runner(recorder: Recorder(), keyDown: mail)
                .run(call("insert_text", ["text": text]))
            guard case .draftStaged(let draft)? = effect else { return XCTFail("no draft") }
            XCTAssertNil(draft.copyOnlyReason, "a tab or a line break outside a terminal is fine")
        }
    }

    /// B1: traces persist, so a draft is kept as its length, in the call and in the
    /// model turn that made it. The band still gets the real text.
    func testATraceKeepsTheDraftsLengthNotItsText() async {
        // Two lines, so the model's JSON carries it escaped (`\n`) and a plain search
        // for the text would miss it.
        let secret = "Board approved the merger at 4.2 billion.\nWe announce Monday."
        let json = #"Board approved the merger at 4.2 billion.\nWe announce Monday."#
        let notes = NotesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("device-\(UUID()).json"), load: false)
        var service = CommandAgentService(
            store: emptyStore(), notes: notes, approvals: ApprovalCoordinator(),
            connectorsAllowed: false)
        service.frontApp = mail
        service.device = DeviceToolRunner.Environment(
            installedApp: { _ in nil }, openApp: { _ in false }, openURL: { _ in false },
            frontApp: { [mail] in mail })
        let run = await service.run(
            "write that the board approved it",
            generate: ScriptedModel([
                #"{"tool":"insert_text","args":{"text":"\#(json)"}}"#,
                #"{"answer":"\#(json)"}"#,
            ]).generate)

        XCTAssertEqual(run.draft?.text, secret)
        XCTAssertEqual(run.calls.first?.arguments["text"], "[draft, \(secret.count) characters]")
        XCTAssertFalse(run.turns.contains { $0.text.contains("merger") }, "\(run.turns)")
        XCTAssertFalse(run.storableAnswer.contains("merger"))
    }

    func testTheJournalKeepsAReplacementsLengthOnly() async {
        let notes = NotesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("device-\(UUID()).json"), load: false)
        let router = CommandToolRouter(
            local: LocalToolRunner(notes: notes), connectors: nil,
            device: runner(recorder: Recorder(), keyDown: mail, selection: selection()))
        _ = await router.run(call("replace_selection", ["text": "Numbers look good."]))
        XCTAssertEqual(router.journal.first?.arguments, ["text": "[draft, 18 characters]"])
    }

    /// B2: a token wider than the column takes a line per column width, so the band
    /// is tall enough (or scrolls) instead of clipping its tail.
    func testALongUnbrokenTokenCountsEveryLineItTakes() {
        let token = String(repeating: "a1B2c3D4e5", count: 30)
        let column: CGFloat = 500
        let needed = Int((NotchTextMetrics.width(token) / column).rounded(.up))
        XCTAssertGreaterThanOrEqual(NotchDraftBanner.lineCount(token, width: column), needed)
        XCTAssertGreaterThan(needed, 1)
    }

    /// A1: a long host is cut at the front, so its real domain stays on the card;
    /// one whose domain cannot fit is refused rather than shown as a prefix.
    func testTheLinkHeadlineKeepsTheDomainOrRefuses() async {
        let host = "login.accounts.google.com.secure-verification-center.attacker-controlled-domain.net"
        let headline = DeviceToolCatalog.linkHeadline(host: host)
        XCTAssertEqual(headline?.hasPrefix("Open \u{2026}"), true, headline ?? "nil")
        XCTAssertEqual(headline?.hasSuffix("attacker-controlled-domain.net in your browser"), true)
        XCTAssertEqual(DeviceToolCatalog.linkHeadline(host: "github.com"), "Open github.com in your browser")
        XCTAssertNil(DeviceToolCatalog.linkHeadline(host: String(repeating: "x", count: 60) + ".co.uk"),
                     "never cut down to the public suffix")

        let recorder = Recorder()
        let (result, _) = await runner(recorder: recorder)
            .run(call("open_url", ["url": "https://" + String(repeating: "a", count: 60) + ".com/"]))
        XCTAssertFalse(result.ok)
        XCTAssertTrue(recorder.cards.isEmpty)
    }

    /// A4: Escape drops a staged draft, even when it also denies a waiting card.
    func testEscapeDropsAStagedDraft() {
        let viewModel = DictationViewModel()
        viewModel.state.agentDraft = AgentDraft.stage(
            .insertText, text: "On my way.", app: mail, selection: nil, selectionWasCut: false,
            frontNow: mail, tainted: false, readOutsideSelection: false)
        viewModel.state.agentDraftAt = Date()
        viewModel.state.approvals.seedPendingForSnapshot(PendingApproval(
            tool: "open_app", instanceID: DeviceToolCatalog.thisMacID,
            instanceLabel: DeviceToolCatalog.thisMacLabel, target: "Figma", arguments: [:]))

        XCTAssertTrue(viewModel.handleAssistantEscape())
        XCTAssertNil(viewModel.state.agentDraft)
        XCTAssertNil(viewModel.state.approvals.pending)
    }

    /// A6: a device call is an action in the trace, and This Mac is not a connector.
    func testATraceShowsADeviceCallAsAnActionNotAConnector() {
        let opened = ToolCallTrace(tool: "open_app", arguments: ["app": "Figma"],
                                   connectors: [DeviceToolCatalog.thisMacLabel], ok: true,
                                   result: "Opened Figma.", milliseconds: 3)
        XCTAssertTrue(opened.isWrite)
        var trace = AssistantTrace(askedAt: Date(), heard: "open figma", asked: "open figma", stages: [])
        trace.calls = [opened]
        XCTAssertTrue(trace.touchedConnectors.isEmpty)
    }

    /// The band shows the draft as it will be typed, a line per line break, and its
    /// tallest form stays inside the panel, which is sized once at window creation.
    func testTheDraftBandKeepsLineBreaksAndFitsThePanel() {
        XCTAssertEqual(NotchDraftBanner.lineCount("Hi Sam,\n\nThanks.\nDana", width: 500), 4)
        XCTAssertLessThanOrEqual(NotchDraftBanner.maxThickness, NotchAgentPanel.maxThickness)
        let long = String(repeating: "line\n", count: 40)
        XCTAssertEqual(NotchDraftBanner.bodyHeight(for: long, width: 500),
                       NotchTextMetrics.blockHeight(lines: NotchDraftBanner.Metrics.maxBodyLines),
                       "past the cap the text scrolls instead of growing the band")
    }

    // MARK: - Phase 2.5 review fixes

    /// A selection over `SelectionReader.limit` is cut, so a rewrite covers only its
    /// head while the paste would replace all of it: copy only when staged, and at the tap.
    func testARewriteOfACutSelectionIsCopyOnly() async {
        let long = String(repeating: "a", count: SelectionReader.limit)
        let cut = SelectionContext(appName: "Mail", windowTitle: nil, text: long,
                                   wasCut: true, originalLength: SelectionReader.limit + 500)
        let (_, effect) = await runner(recorder: Recorder(), keyDown: mail, selection: cut)
            .run(call("replace_selection", ["text": "Shorter."]))
        guard case .draftStaged(let draft)? = effect else { return XCTFail("no draft") }
        XCTAssertEqual(draft.copyOnlyReason, AgentDraft.selectionCut)
        XCTAssertEqual(draft.copyOnlyReason,
                       "The selection was too long to rewrite safely, so this is copy only.")
        XCTAssertEqual(draft.actionTitle, "Copy")

        // A draft staged from a whole selection, which has grown past the limit by the tap.
        let (_, whole) = await runner(recorder: Recorder(), keyDown: mail, selection: selection())
            .run(call("replace_selection", ["text": "Shorter."]))
        guard case .draftStaged(let staged)? = whole else { return XCTFail("no draft") }
        XCTAssertNil(staged.copyOnlyReason)
        let grown = SelectionContext(appName: "Mail", windowTitle: nil, text: selection().text,
                                     wasCut: true, originalLength: SelectionReader.limit + 1)
        XCTAssertEqual(staged.selectionBlocker(current: .selected(grown)), AgentDraft.selectionCut)
        XCTAssertNil(staged.selectionBlocker(current: .selected(selection())),
                     "the same whole selection may be replaced")
        XCTAssertEqual(staged.selectionBlocker(current: .selected(selection("Other text."))),
                       AgentDraft.selectionChanged)
        XCTAssertEqual(staged.selectionBlocker(current: .empty), AgentDraft.selectionChanged)
        XCTAssertEqual(staged.selectionBlocker(current: .unknown), AgentDraft.selectionChanged,
                       "a Replace needs the exact text it was written for")
    }

    /// ⌘V over a selection replaces it, so an Insert re-reads the selection at the tap.
    /// Text selected after staging, or never read by the model, makes it copy only.
    func testAnInsertOverASelectionIsCopyOnlyAtTheTap() async {
        let (_, effect) = await runner(recorder: Recorder(), keyDown: mail, selection: selection())
            .run(call("insert_text", ["text": "On my way."]))
        guard case .draftStaged(let draft)? = effect else { return XCTFail("no draft") }
        XCTAssertNil(draft.copyOnlyReason, "staged before the tap's own read")

        XCTAssertEqual(draft.selectionBlocker(current: .selected(selection())), AgentDraft.textSelected)
        XCTAssertEqual(draft.selectionBlocker(current: .selected(selection())),
                       "Text is selected, so inserting would replace it. This is copy only.")
        XCTAssertNil(draft.selectionBlocker(current: .empty), "with nothing selected the tap types")
        XCTAssertEqual(draft.typedLine(after: .empty), "Typed the draft into Mail.")
        XCTAssertEqual(draft.copyOnly(AgentDraft.textSelected).actionTitle, "Copy")
    }

    /// Chrome and Electron (Slack, VS Code) hide their selection, and a hung app runs
    /// out the wait. Insert still types there, the most common place it is used, and
    /// the status line says that a selection may have been replaced.
    func testAnInsertOverAnUnknownSelectionTypesAndSaysHowToUndo() async {
        let slack = SelectionReader.FrontApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", pid: 403)
        let (_, effect) = await runner(recorder: Recorder(), keyDown: slack)
            .run(call("insert_text", ["text": "On my way."]))
        guard case .draftStaged(let draft)? = effect else { return XCTFail("no draft") }

        XCTAssertNil(draft.selectionBlocker(current: .unknown), "unknown is not a reason to copy")
        let line = draft.typedLine(after: .unknown)
        XCTAssertEqual(line, AgentDraft.typedOverUnknownSelection)
        XCTAssertTrue(line.contains("Cmd-Z"))
        XCTAssertLessThanOrEqual(line.count, 60)
        XCTAssertNotEqual(line, draft.typedLine(after: .empty), "a known-empty selection keeps the old line")
    }

    /// ⌘V in a terminal types at the prompt and replaces nothing, so an Insert there
    /// skips the selection check: highlighted text must not make it copy only.
    func testAnInsertInATerminalSkipsTheSelectionCheck() async {
        let (_, insert) = await runner(recorder: Recorder(), keyDown: terminal)
            .run(call("insert_text", ["text": "git status"]))
        guard case .draftStaged(let inTerminal)? = insert else { return XCTFail("no draft") }
        XCTAssertFalse(inTerminal.readsSelectionAtTap)
        XCTAssertEqual(inTerminal.typedLine(after: nil), "Typed the draft into Terminal.")

        let (_, mailInsert) = await runner(recorder: Recorder(), keyDown: mail)
            .run(call("insert_text", ["text": "On my way."]))
        guard case .draftStaged(let inMail)? = mailInsert else { return XCTFail("no draft") }
        XCTAssertTrue(inMail.readsSelectionAtTap)

        let (_, replace) = await runner(recorder: Recorder(), keyDown: terminal, selection: selection("ls -la"))
            .run(call("replace_selection", ["text": "ls -lah"]))
        guard case .draftStaged(let replaceInTerminal)? = replace else { return XCTFail("no draft") }
        XCTAssertTrue(replaceInTerminal.readsSelectionAtTap, "a Replace always checks its selection")
    }

    /// The endpoint writes `<tool_call>{"name":…}`, not `{"tool":…}`. The trace keeps
    /// the draft's own length in both shapes, and never its text.
    func testATraceKeepsTheDraftLengthInEitherCallShape() throws {
        let draft = "Board approved the merger.\nWe announce Monday."
        let json = #"Board approved the merger.\nWe announce Monday."#
        let handRolled = #"{"tool":"insert_text","args":{"text":"\#(json)"}}"#
        let endpoint = try XCTUnwrap(CloudToolGenerator.toolCallText(name: "insert_text",
                                                                     arguments: ["text": draft]))
        XCTAssertTrue(endpoint.hasPrefix("<tool_call>"))
        for turn in [handRolled, endpoint] {
            let kept = DeviceToolCatalog.storableTurn(turn)
            XCTAssertEqual(kept, #"{"tool":"insert_text","args":{"text":"[draft, \#(draft.count) characters]"}}"#,
                           turn)
            XCTAssertFalse(kept.contains("merger"), turn)
        }
    }

    func testReplaceSelectionIsOfferedOnlyWithASelection() {
        XCTAssertFalse(DeviceToolCatalog.offered(selection: false, frontApp: true)
            .map(\.name).contains("replace_selection"))
        XCTAssertTrue(DeviceToolCatalog.offered(selection: true, frontApp: true)
            .map(\.name).contains("replace_selection"))
        XCTAssertEqual(DeviceToolCatalog.offered(selection: true, frontApp: false).map(\.name),
                       ["open_app", "open_url"], "no draft tools without an app to type into")
    }
}
