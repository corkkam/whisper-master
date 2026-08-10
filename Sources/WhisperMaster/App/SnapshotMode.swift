import AppKit
import SwiftUI

/// True while rendering design snapshots. Production code leaves this false; the
/// two AppKit-backed controls (the hotkey `Menu` and the vocabulary `TextEditor`)
/// substitute a static SwiftUI stand-in when it's set, since `ImageRenderer`
/// can't draw AppKit controls.
private struct SnapshotEnvironmentKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotEnvironmentKey.self] }
        set { self[SnapshotEnvironmentKey.self] = newValue }
    }
}

#if DEBUG
/// Renders the app's SwiftUI surfaces to PNG files using `ImageRenderer`, with
/// no window or screen access — used to iterate on the design headlessly.
/// Triggered via the `WM_SNAPSHOT=<dir>` environment variable (see AppMain).
/// DEBUG-only design tooling; compiled out of shipping Release builds.
@MainActor
enum SnapshotMode {
    static func run(outputDirectory: String) {
        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let viewModel = DictationViewModel()
        seedMockData(viewModel.state)
        let state = viewModel.state

        // Full window (top-tab masthead + body). The detail ScrollView may
        // collapse in ImageRenderer, so the per-section panels below carry the body.
        for section in [SettingsSection.settings, .history, .engine] {
            render(
                SettingsView(viewModel: viewModel, state: state, initialSection: section)
                    .frame(width: 900, height: 700),
                to: dir.appendingPathComponent("window-\(section.rawValue).png")
            )
        }

        // Notes gets its own full-window render, wider than the rest: it's the only
        // section with an expandable sidebar group, and the only way to check that the
        // group's sub-rows read as subordinate to their parent is to see them beside
        // the other four nav items. 900pt would also squeeze the canvas into one
        // column and hide the layout being checked.
        render(
            SettingsView(viewModel: viewModel, state: state, initialSection: .notes)
                .frame(width: 1320, height: 820),
            to: dir.appendingPathComponent("window-notes.png")
        )

        // Each section's panel on its own (ImageRenderer collapses flexible
        // ScrollViews, so we render the fixed detail container instead).
        for section in SettingsSection.allCases {
            render(
                detailContainer(section: section, viewModel: viewModel, state: state),
                to: dir.appendingPathComponent("panel-\(section.rawValue).png")
            )
        }

        // Notes & Reminders is three surfaces behind one section — the split
        // overview, the sticky canvas, and the reminders list — so the one
        // `panel-notes` render above only covers a third of it.
        for tab in NotesTab.allCases {
            render(
                detailContainer(section: .notes, viewModel: viewModel, state: state, notesTab: tab),
                to: dir.appendingPathComponent("panel-notes-\(tab.rawValue).png")
            )
        }

        // The account popup that hangs off the sidebar profile row (it replaced
        // the Account page, so it has no section panel of its own).
        let accountPopover = AccountPopoverCard(
            displayName: "Alex Rivera",
            email: "alex@whispermaster.app",
            accountID: "user_2aBcDeFgHiJkLmN",
            memberSince: "Joined June 2026",
            imageURL: nil,
            signOut: {}
        )
        .background(Theme.surface)
        .padding(20)
        .background(Color(white: 0.9))
        render(accountPopover, to: dir.appendingPathComponent("panel-account-popover.png"))

        // Onboarding, in the notch — one render per beat, plus the two states
        // inside the microphone beat that the orb is doing the work in.
        renderOnboarding(dir, name: "onboarding-1-microphone", state: state) {
            .snapshot(step: .microphone)
        }
        renderOnboarding(dir, name: "onboarding-1b-mic-listening", state: state) {
            .snapshot(step: .microphone, micGranted: true, level: 0.34)
        }
        renderOnboarding(dir, name: "onboarding-1c-mic-heard", state: state) {
            .snapshot(step: .microphone, micGranted: true, heardVoice: true, level: 0.5)
        }
        renderOnboarding(dir, name: "onboarding-2-accessibility", state: state) {
            .snapshot(step: .accessibility, micGranted: true)
        }
        renderOnboarding(dir, name: "onboarding-3-open-at-login", state: state) {
            .snapshot(step: .openAtLogin, micGranted: true, accessibilityGranted: true)
        }
        // The state that looks enabled and isn't: registered, held by macOS until
        // the user approves it under Login Items.
        renderOnboarding(dir, name: "onboarding-3b-login-needs-approval", state: state) {
            .snapshot(
                step: .openAtLogin,
                micGranted: true,
                accessibilityGranted: true,
                launchAtLoginNeedsApproval: true)
        }
        renderOnboarding(dir, name: "onboarding-4-ready", state: state) {
            .snapshot(
                step: .ready,
                micGranted: true,
                accessibilityGranted: true,
                launchAtLoginEnabled: true)
        }

        // The hover quick-actions band: what the notch holds when the pointer rests
        // on it. Both states, since the empty one is what a fresh account sees.
        renderReplyCandidates(dir)
        renderQuickActions(dir, name: "quick-actions", state: state)
        renderQuickActions(dir, name: "quick-actions-empty", state: AppState())

        // Notch pill / moment-of-truth states. The dark surface is rendered on a
        // neutral backdrop so the black band reads. Each state uses its own fresh
        // AppState so the fields don't bleed across renders.
        // Recording — the menu-bar row, with the state in words at the leading edge
        // and the orb at the trailing one.
        renderPill(dir, name: "pill-0-listening-empty") { s in
            s.phase = .recording
            s.audioLevel = 0.18
        }
        // Latched by a double-tap — "Dictating (hands-free)" is the longest state
        // word there is, and `wideSideExtension` is sized to it. If this one ever
        // renders truncated or runs under the camera housing, the wing is too short.
        // Set via `handsFreeActive` (transient) rather than `holdToTalkEnabled`,
        // which persists — a headless render must not rewrite the user's settings.
        renderPill(dir, name: "pill-0b-listening-hands-free") { s in
            s.phase = .recording
            s.handsFreeActive = true
            s.audioLevel = 0.3
        }
        // The same row *with words streaming in*, which must look identical to the
        // one above: the band never shows the live transcript. This render is the
        // regression check on that, so don't "fix" it by expecting a wide band.
        renderPill(dir, name: "pill-1-listening-transcript-hidden") { s in
            s.phase = .recording
            s.audioLevel = 0.42
            s.transcript.latestConfirmed = "let's ship the notch transcript today and"
            s.transcript.latestPartial = "see how it reads"
        }
        renderPill(dir, name: "pill-2-finalizing") { s in
            s.phase = .stopping
            s.transcript.latestConfirmed = "let's ship the notch transcript today"
        }
        renderPill(dir, name: "pill-3-delivered") { s in
            s.phase = .idle
            s.deliveredAt = Date()
        }
        renderPill(dir, name: "pill-4-failed") { s in
            s.phase = .failed("The network appears to be offline")
            s.failedAt = Date()
            s.statusMessage = "Transcription failed: The network appears to be offline"
        }
        renderPill(dir, name: "pill-5-undelivered") { s in
            s.phase = .idle
            s.undeliveredText = "Ship the notch transcript today and see how it reads."
            s.undeliveredTranscriptAt = Date()
        }
        renderPill(dir, name: "pill-6-bluetooth") { s in
            s.phase = .idle
            s.bluetoothInputActive = true
        }
        // A reminder that has come due — this is where the app's own scheduled
        // alerts land instead of Notification Centre.
        renderPill(dir, name: "pill-6b-due-reminder") { s in
            s.phase = .idle
            s.dueReminder = ReminderItem(
                title: "Call Migner",
                dueDate: Date(),
                alertStyle: .notification
            )
            s.dueReminderAt = Date()
        }
        // …and the same band after the checkbox has been ticked, which holds for a
        // short undo window rather than vanishing on the click.
        renderPill(dir, name: "pill-6c-due-reminder-done") { s in
            s.phase = .idle
            s.dueReminder = ReminderItem(
                title: "Call Migner",
                dueDate: Date(),
                alertStyle: .notification
            )
            s.dueReminderAt = Date()
            s.dueReminderCompleted = true
        }
        // An assistant answer being read aloud: the calendar glyph gives way to the
        // speaker, and the band's expiry clock is paused for the duration.
        renderPill(dir, name: "pill-6d-day-summary-speaking") { s in
            s.phase = .idle
            s.activeDaySummary = DaySummary(
                headline: "Three meetings, first at ten.",
                detail: "From Work calendar",
                events: [], gaps: [], scopedTo: nil)
            s.daySummaryAt = Date()
            s.daySummaryWasSpoken = true
            s.isSpeakingAnswer = true
        }
        // The assistant working, captioned by the connector it's waiting on rather
        // than by one static "Working on it" for the whole 30-second budget. The
        // chord suppresses the paste, so this row is the only thing saying the words
        // went anywhere.
        renderPill(dir, name: "pill-7b-agent-reading-calendar") { s in
            s.phase = .idle
            s.isPolishing = true
            s.commandAgentRunning = true
            s.agentActivity = .running(tool: "list_calendar_events", target: "Personal")
        }
        // An unqualified read merges every calendar, so it says so rather than
        // naming one of them.
        renderPill(dir, name: "pill-7c-agent-all-calendars") { s in
            s.phase = .idle
            s.isPolishing = true
            s.commandAgentRunning = true
            s.agentActivity = .running(tool: "list_calendar_events", target: nil)
        }
        // A second connector in the same run — the caption follows the work across.
        renderPill(dir, name: "pill-7d-agent-posting-to-slack") { s in
            s.phase = .idle
            s.isPolishing = true
            s.commandAgentRunning = true
            s.agentActivity = .running(tool: "send_message", target: "#eng-standup")
        }
        // The regression check on the wing: a long connection name must widen the
        // bar, not slide under the camera housing. If the caption here is clipped or
        // runs into the housing, `maxStateLabelWing` is too small.
        renderPill(dir, name: "pill-7e-agent-long-connector-name") { s in
            s.phase = .idle
            s.isPolishing = true
            s.commandAgentRunning = true
            s.agentActivity = .running(
                tool: "list_calendar_events", target: "Personal Google Calendar")
        }
        // The consent card for a connector write — the one banner that carries three
        // buttons beside its two lines, so it takes the *wide* surface. These two
        // renders are the regression check on the card that shipped unreadable: raw
        // arguments ("start: 2026-08-08T09:00:00+05:30 · title: Work · when: …")
        // under "Add an event to Personal on Personal", laid out at banner width
        // with `fixedSize`, which ran the words off both edges and pushed Once /
        // Always / No out past the band's clip where they couldn't be clicked.
        renderPill(dir, name: "pill-9-approval-calendar") { s in
            s.phase = .idle
            let start = Date()
            s.approvals.seedPendingForSnapshot(PendingApproval(
                tool: "create_calendar_event",
                instanceID: UUID(),
                instanceLabel: "Personal",
                target: "Personal",
                arguments: [
                    "title": "Work",
                    "when": "tomorrow at nine",
                    "start": ConnectorHTTP.iso8601(from: start),
                    "end": ConnectorHTTP.iso8601(from: start.addingTimeInterval(30 * 60)),
                    ToolDescriptor.instanceArgument: "Personal",
                ]))
        }
        // A dictated message body has no length limit, so this is the case that
        // decides whether the payload gives way or the answers do. The three buttons
        // must be whole and on-band; the quoted text truncates at the tail.
        renderPill(dir, name: "pill-9b-approval-long-message") { s in
            s.phase = .idle
            s.approvals.seedPendingForSnapshot(PendingApproval(
                tool: "send_message",
                instanceID: UUID(),
                instanceLabel: "Work",
                target: "#eng-standup",
                arguments: [
                    "channel": "#eng-standup",
                    "text": "Running about ten minutes late this morning, please start "
                        + "without me and I'll catch up on the thread afterwards.",
                    ToolDescriptor.instanceArgument: "Work",
                ]))
        }
        // A coding agent asking to run a command. Same three answers as the connector
        // card above, because it is the same question: the payload is unbounded, so
        // it must be the words that give way and never the buttons.
        renderPill(dir, name: "pill-10-agent-run") { s in
            s.phase = .idle
            s.agents.seedForSnapshot(
                ask: .approval(
                    AgentApproval(
                        requestID: "r1", tool: "Bash",
                        headline: "Run  rm -rf build/ && swift build -c release",
                        detail: "whisper-master")),
                sessions: [
                    AgentSession(
                        id: "s1", repo: "whisper-master", state: .awaitingPermission),
                    AgentSession(
                        id: "s2", repo: "kunai", state: .running,
                        activity: "Editing loop.go",
                        turnStartedAt: Int64(Date().addingTimeInterval(-17).timeIntervalSince1970 * 1000)),
                    AgentSession(id: "s3", repo: "landing-page", state: .idle),
                ])
        }
        // The choice card: options are model-authored sentences, so they stack and
        // the band grows a row at a time. This is the case that proves a choice is
        // not the approval card with different words.
        renderPill(dir, name: "pill-10b-agent-choice") { s in
            s.phase = .idle
            s.agents.seedForSnapshot(
                ask: .choice(
                    AgentChoice(
                        requestID: "r2",
                        questions: [
                            .init(
                                text: "How should the retry back off?",
                                header: "Retry", multiSelect: false,
                                options: [
                                    "Exponential, capped at 30s",
                                    "Fixed 5s between attempts",
                                    "Give up after the first failure",
                                ])
                        ],
                        context: "whisper-master"),
                ),
                sessions: [
                    AgentSession(id: "s1", repo: "whisper-master", state: .awaitingPermission),
                    AgentSession(id: "s2", repo: "kunai", state: .idle),
                ])
        }
        // The surface you open rather than the one that interrupts you: a tap of the
        // agent key. Rows, not cards — the version with three equal cards read as a
        // dropdown menu pinned under the notch.
        renderPill(dir, name: "pill-10c-agent-glance") { s in
            s.phase = .idle
            s.agents.seedGlanceForSnapshot(sessions: [
                AgentSession(
                    id: "s1", repo: "whisper-master", state: .awaitingPermission,
                    activity: "Run  rm -rf build/"),
                AgentSession(
                    id: "s2", repo: "kunai", state: .running,
                    activity: "Editing internal/session/loop.go",
                    turnStartedAt: Int64(
                        Date().addingTimeInterval(-17).timeIntervalSince1970 * 1000)),
                AgentSession(id: "s3", repo: "landing-page", state: .idle),
            ])
        }
        // Mid-turn: the slim row, not the panel. A turn runs for minutes, and a
        // panel-height band over the menu bar for minutes is an obstruction rather
        // than ambient awareness. This must stay the same height as the dictation
        // row it borrows its shape from.
        renderPill(dir, name: "pill-10e-agent-working") { s in
            s.phase = .idle
            s.agents.seedGlanceForSnapshot(
                sessions: [
                    AgentSession(
                        id: "s1", repo: "whisper-master", state: .running,
                        activity: "Editing NotchGlow.swift",
                        turnStartedAt: Int64(
                            Date().addingTimeInterval(-17).timeIntervalSince1970 * 1000))
                ],
                openSessionID: "s1")
            s.agents.reveal(sessionID: "s1")
        }
        // The finished turn, as one banner line: the same icon-title-subtitle shape
        // every other band in this app uses. It replaced a dense transcript with role
        // labels and monospaced tool rows, which was a log file on the bezel.
        renderPill(dir, name: "pill-10d-agent-reply") { s in
            s.phase = .idle
            s.agents.seedReplyForSnapshot(
                session: AgentSession(id: "s1", repo: "whisper-master", state: .idle),
                reply: "Cleared the build and rewrote the route assertion to wait on the "
                    + "rebuilt engine instead of a fixed delay.",
                duration: 192)
        }
        // The same reply, clicked open (or arriving open via the Settings toggle):
        // full markdown as prose and code, what changed, and where the rest lives.
        renderPill(dir, name: "pill-10f-agent-reply-expanded") { s in
            s.phase = .idle
            s.agents.seedReplyForSnapshot(
                session: AgentSession(id: "s1", repo: "whisper-master", state: .idle),
                reply: """
                    Ran both. Here's what's available:

                    ## Toolchain

                    | tool | version |
                    |---|---|
                    | swift | 6.3.3, arm64-apple-macosx26.0 |
                    | xcodebuild | Xcode 26.6, build 17F113 |
                    | xcodegen | 2.44.1 |

                    ## Worktrees

                    ```
                    ~/conductor/workspaces/whisper-master/hat-yai        mic-testing-transcribes-wrong  fdb7411
                    ~/conductor/workspaces/whisper-master/pattaya        feat/notch-agent-surface       7140bb5
                    ~/conductor/workspaces/whisper-master/san-francisco  ux-onbaord-better              dd1a7cd
                    ```

                    All 42 tests pass. The flake was the fixed delay racing the \
                    engine rebuild on slower runs.

                    ## What is still parked

                    1. **1.1.0 is stuck mid-release.** Beta.4 shipped the audio \
                    crash fix, `release/1.1.0` is still open on origin, and nothing \
                    has been merged to `main` or tagged.
                    2. **A bug branch that may or may not be dead.** \
                    `mic-testing-transcribes-wrong` is parked in the `hat-yai` \
                    worktree, and CLAUDE.md describes that bug as fixed.
                    3. **Four worktrees carrying unmerged branches**, which is more \
                    parked work than the branch list suggested.
                    """,
                duration: 192,
                prompt: "Fix the flaky audio route test, and clear the build first.",
                turnEvents: Array(sessionTranscriptEvents.dropFirst()))
            s.agents.toggleReplyExpansion()
        }
        // The commonest turn of all: a question that called no tools and changed
        // nothing. There is no run to put in a rail, so the question goes full
        // width and the answer takes the whole card — a 306pt strip holding one
        // line beside a full answer was a third of the surface doing nothing.
        renderPill(dir, name: "pill-10g-agent-reply-answer-only") { s in
            s.phase = .idle
            s.agents.seedReplyForSnapshot(
                session: AgentSession(id: "s1", repo: "whisper-master", state: .idle),
                reply: """
                    Per directory:

                    ```
                    Sources/     WhisperMaster/ → 21 modules
                    Tests/       WhisperMasterTests/ → 50 test files + Fixtures/
                    Resources/   AppIcon.icns  Info.plist  WhisperMaster.entitlements
                    Scripts/     14 files — bundle.sh release.sh install.sh dev-install.sh
                    eval/        dashboard/  text-cleanup/
                    docs/        design/  superpowers/  supabase-clerk-integration.md
                    .github/     CI workflows
                    ```

                    Generated or scratch, nothing meaningful inside: `.build/`, \
                    `build/`, `.context/`, `.swiftpm/`, `WhisperMaster.xcodeproj/`, \
                    `.git/`.
                    """,
                duration: 9,
                prompt: "So tell me what are there in the directories.")
            s.agents.toggleReplyExpansion()
        }
        renderPill(dir, name: "pill-7-polishing") { s in
            s.phase = .idle
            s.isPolishing = true
            s.transcript.latestConfirmed = "so like let's ship the notch transcript today"
        }
        // The polished beat is now the only band that carries text, so it is where
        // the wrap and the rolling window get exercised.
        renderPill(dir, name: "pill-8-polished") { s in
            s.phase = .idle
            s.polishedText = "Let's ship the notch transcript today."
            s.polishedAt = Date()
        }
        // Two wrapped lines — the band has grown a row but nothing has scrolled.
        renderPill(dir, name: "pill-8b-polished-two-lines") { s in
            s.phase = .idle
            s.polishedText = "Let's ship the notch transcript today and see how it reads once the words start wrapping onto a second line."
            s.polishedAt = Date()
        }
        // Past three lines — the oldest text has scrolled off behind the top fade.
        renderPill(dir, name: "pill-8c-polished-scrolled") { s in
            s.phase = .idle
            s.polishedText = "Yesterday I walked down to the harbour to watch the boats come in. The water was calm and the air smelled like salt and diesel. An old fisherman was mending his net on the dock and he nodded at me as I passed. Further along, a group of kids were dropping crab lines off the pier and shouting every time one of them caught something."
            s.polishedAt = Date()
        }

        print("Snapshots written to \(dir.path)")
        exit(0)
    }

    /// Render the notch onboarding band in a single pinned beat, on the same
    /// neutral backdrop the pill snapshots use so the black surface reads.
    private static func renderOnboarding(
        _ dir: URL,
        name: String,
        state: AppState,
        model: () -> NotchOnboardingModel
    ) {
        let layout = NotchOnboardingLayout()
        // Size the stand-in panel exactly as the real one, so a layout change
        // can't silently clip the snapshot.
        let panel = layout.panelSize(for: .none)
        let view = ZStack(alignment: .top) {
            Color(white: 0.28)
            NotchOnboardingView(model: model(), state: state, layout: layout)
                .frame(width: panel.width, height: panel.height, alignment: .top)
        }
        .frame(width: panel.width + 92, height: panel.height + 60)
        render(view, to: dir.appendingPathComponent("\(name).png"))
    }

    /// A stand-in for the hardware every user actually has: the built-in Retina
    /// display's measured notch (`safeAreaInsets.top = 37.5`, 208pt housing on a
    /// 1710pt-wide screen).
    ///
    /// The pill snapshots used to render with `.none`, which has **no notch** — so
    /// the camera dead-zone, the menu-bar row, and the screen-width clamp were all
    /// absent from every snapshot, i.e. the harness was silently checking a layout
    /// no user sees. The width clamp makes these images wide; that is the real
    /// surface width.
    private static let snapshotNotch = NotchGeometry(
        notchWidth: 208, notchHeight: 37.5, screenWidth: 1710, screenHeight: 1107
    )

    /// Render the notch pill in a single state onto a neutral backdrop.
    /// Render the hover quick-actions band on the same stand-in bezel the pill and
    /// onboarding snapshots use, sized exactly as the real panel so a layout change
    /// can't silently clip it.
    private static func renderQuickActions(_ dir: URL, name: String, state: AppState) {
        let layout = NotchQuickActionsLayout()
        let geometry = snapshotNotch
        let model = NotchQuickActionsModel(state: state)
        let panel = layout.panelSize(for: geometry, rows: model.visibleRowCount)
        let view = ZStack(alignment: .top) {
            Color(white: 0.28)
            NotchQuickActionsView(
                model: model,
                geometry: geometry,
                layout: layout
            )
            .frame(width: panel.width, height: panel.height, alignment: .top)
        }
        .frame(width: panel.width + 92, height: panel.height + 60)
        render(view, to: dir.appendingPathComponent("\(name).png"))
    }

    /// A believable turn for the session-view snapshot, built from real wire frames
    /// so the render exercises the same reducer the app does.
    private static var sessionTranscriptEvents: [KunaiWire.Event] {
        let json = [
            #"{"seq":1,"t":"user","text":"Fix the flaky audio route test, and clear the build first."}"#,
            #"{"seq":2,"t":"assistant","blocks":[{"type":"tool_use","id":"t1","name":"Bash"}]}"#,
            #"{"seq":3,"t":"permission","request_id":"r1","tool_use_id":"t1","tool_name":"Bash","input":{"command":"rm -rf build/"}}"#,
            #"{"seq":4,"t":"permission_resolved","request_id":"r1","tool_use_id":"t1","behavior":"allow"}"#,
            #"{"seq":5,"t":"assistant","blocks":[{"type":"tool_use","id":"t2","name":"Edit"}]}"#,
            #"{"seq":6,"t":"permission","request_id":"r2","tool_use_id":"t2","tool_name":"Edit","input":{"file_path":"/x/Sources/UI/NotchGlow.swift"}}"#,
            #"{"seq":7,"t":"tool_result","tool_use_id":"t2"}"#,
            #"{"seq":8,"t":"assistant","blocks":[{"type":"text","text":"Cleared the build and rewrote the route assertion."}]}"#,
        ]
        return json.compactMap {
            try? JSONDecoder().decode(KunaiWire.Event.self, from: Data($0.utf8))
        }
    }

    private static func renderPill(_ dir: URL, name: String, configure: (AppState) -> Void) {
        let state = AppState()
        state.hidePillWhenIdle = false
        configure(state)
        // Size the stand-in panel exactly as the real one, so a layout change to
        // `NotchSurfaceLayout` can't silently clip the snapshot.
        let geometry = snapshotNotch
        let panel = NotchSurfaceLayout().panelSize(for: geometry)
        let view = ZStack(alignment: .top) {
            // A pale backdrop, so the black surface and the dead-zone above the
            // band are both legible as shapes.
            Color(white: 0.28)
            DictationPillContent(state: state, geometry: geometry)
                .frame(width: panel.width, height: panel.height, alignment: .top)
        }
        .frame(width: panel.width + 92, height: panel.height + 60)
        render(view, to: dir.appendingPathComponent("\(name).png"))
    }

    @ViewBuilder
    private static func sectionView(
        _ section: SettingsSection,
        viewModel: DictationViewModel,
        state: AppState,
        notesTab: NotesTab = .overview
    ) -> some View {
        switch section {
        case .today: TodayView(viewModel: viewModel, state: state)
        case .insights: InsightsSettingsView(viewModel: viewModel, state: state)
        case .notes: NotesSettingsView(state: state, tab: .constant(notesTab))
        case .connectors: ConnectorsSettingsView(state: state)
        case .settings: GeneralSettingsView(viewModel: viewModel, state: state)
        case .engine: EngineSettingsView(viewModel: viewModel, state: state)
        case .mesh: MeshSettingsView(viewModel: viewModel, state: state)
        case .history: HistorySettingsView(viewModel: viewModel, state: state)
        case .permissions:
            PermissionsSettingsView(permissions: PermissionsManager(), micGranted: true, micDenied: false, accessibilityGranted: false)
        case .about: AboutSettingsView(state: state)
        }
    }

    private static func detailContainer(
        section: SettingsSection,
        viewModel: DictationViewModel,
        state: AppState,
        notesTab: NotesTab = .overview
    ) -> some View {
        // The notes canvas is laid out against the wider measure the real window
        // gives it (`SettingsView.contentMaxWidth`), so rendering it at the 680pt
        // reading measure would snapshot a layout the app never shows.
        let width: CGFloat = section == .notes ? 1080 : 680
        return VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 7) {
                KickerLabel(section.kicker)
                Text(section.title).font(Typography.largeTitle).tracking(Typography.largeTitleTracking).foregroundStyle(Theme.textPrimary)
                Text(section.subtitle).font(Typography.body).foregroundStyle(Theme.textSecondary)
            }
            sectionView(section, viewModel: viewModel, state: state, notesTab: notesTab)
        }
        .frame(width: width, alignment: .leading)
        .padding(.horizontal, 44)
        .padding(.vertical, 40)
        .frame(width: width + 88, alignment: .topLeading)
        .background(WarmBackground())
    }

    private static func seedMockData(_ state: AppState) {
        state.phase = .idle
        state.audioLevel = 0
        state.customVocabulary = ["RAG", "Parakeet", "Lyzr"]
        state.history = [
            TranscriptHistoryEntry(text: "Let's ship the redesign and get feedback from the team before the demo on Friday.", createdAt: Date(timeIntervalSinceNow: -300), engineRawValue: TranscriberEngine.slidingWindow.rawValue),
            TranscriptHistoryEntry(text: "Remember to sync the FluidAudio version across Package.swift and project.yml.", createdAt: Date(timeIntervalSinceNow: -3600), engineRawValue: TranscriberEngine.slidingWindow.rawValue),
            TranscriptHistoryEntry(text: "The quick brown fox jumps over the lazy dog.", createdAt: Date(timeIntervalSinceNow: -7200), engineRawValue: TranscriberEngine.slidingWindow.rawValue),
        ]
        // Assigned directly rather than through `appendAnswer`, which persists — the
        // renderer must never write into a real user's defaults (same reason `history`
        // is set the same way above).
        state.answerLog = [
            AnsweredQuestion(
                question: "what's on my calendar today",
                answer: "You have three meetings. Standup at ten, the design review at one, and a one-to-one with Priya at four. Your afternoon is otherwise clear until then.",
                provenance: "From Work, Personal",
                askedAt: Date(timeIntervalSinceNow: -420)),
            AnsweredQuestion(
                question: "what needs me today",
                answer: "Two things need you today: the release notes, and Friday's demo script.",
                askedAt: Date(timeIntervalSinceNow: -9000)),
        ]
        seedUsage(state.usageStore)
        seedNotes(state.notesStore)
        // Two *differently named* Google Calendar instances plus an iCal one, so the
        // multi-instance UI — the whole point of the redesign — is visible in the
        // headless renderer rather than only on a Mac with real accounts attached.
        // Persistence off on both the store and the Keychain, so seeding can never
        // touch a real per-account file or prompt for keychain access.
        state.connectorStore.persistenceEnabled = false
        ConnectorCredentials.persistenceEnabled = false
        state.connectorStore.add(ConnectorInstance(
            kind: .googleCalendar, label: "Work", identity: "sam@acme.com",
            config: .calendars(identifiers: ["mock-work"], sourceTitle: "Google")))
        state.connectorStore.add(ConnectorInstance(
            kind: .googleCalendar, label: "Personal", identity: "sam@gmail.com",
            config: .calendars(identifiers: ["mock-personal"], sourceTitle: "Google")))
        state.connectorStore.add(ConnectorInstance(
            kind: .appleCalendar, label: "iCloud", identity: "iCloud",
            config: .calendars(identifiers: ["mock-icloud"], sourceTitle: "iCloud")))
        state.connectorStore.calendarAccessGranted = true
        // The assistant on plus one standing permission, so the Connectors page's
        // grant list and the Settings page's assistant sections both render
        // headlessly rather than only their empty states.
        state.connectorAgentEnabled = true
        state.cleanupModelReady = true
        let mockSlack = state.connectorStore.add(ConnectorInstance(
            kind: .slack, label: "Work chat", identity: "Acme / whisper"))
        state.connectorStore.addGrant(
            Grant(tool: "send_message", instanceID: mockSlack.id, target: "#standup"))
    }

    /// A couple of believable notes + reminders so the Notes & Reminders panel
    /// renders with real-looking content (never touches a real per-account file).
    private static func seedNotes(_ store: NotesStore) {
        store.persistenceEnabled = false
        // A spread that exercises the canvas rather than just filling it: a pinned
        // note (leads the grid, shows the notch band), spoken notes carrying a
        // transcript distinct from the body, and typed notes with neither. The
        // `colorIndex` is set explicitly so the PNGs are stable — the default is
        // derived from a random UUID, which would reshuffle the palette every run
        // and make every snapshot diff look like a redesign.
        //
        // `audio` names files that don't exist, which is the point: the card must
        // render the recording affordance and still refuse to promise playback for a
        // file this Mac doesn't have (the synced-note case).
        store.upsertNote(Note(
            title: "Wifi password",
            body: "The guest network password is basalt-harbour-19.",
            isPinned: true,
            transcript: "take a note that the guest network password is basalt harbour nineteen",
            audio: NoteAudio(fileName: "mock-wifi.wav", durationMs: 7_400),
            colorIndex: 0))
        store.upsertNote(Note(
            title: "Demo script",
            body: "Open with the notch pill, then dictate into Slack to show live paste.",
            colorIndex: 1))
        store.upsertNote(Note(
            title: "Parakeet window",
            body: "Preview track is 1.5s; accurate track stays at 11s — don't lower it.",
            transcript: "note that the preview track is one point five seconds and the accurate track stays at eleven seconds, don't lower it",
            audio: NoteAudio(fileName: "mock-parakeet.wav", durationMs: 12_900),
            colorIndex: 2))
        store.upsertNote(Note(
            title: "Follow-ups",
            body: "Ping design about the Daylight tokens; sync FluidAudio version.",
            colorIndex: 3))
        store.upsertNote(Note(
            title: "",
            body: "Ask Priya whether the compliance deck needs the on-device diagram.",
            colorIndex: 4))
        store.upsertReminder(ReminderItem(
            title: "Stand-up",
            body: "Daily team sync",
            dueDate: Date(timeIntervalSinceNow: 3_600),
            alertStyle: .notification,
            soundName: "Ping",
            repeatRule: .daily))
        store.upsertReminder(ReminderItem(
            title: "Ship the release build",
            dueDate: Date(timeIntervalSinceNow: 7_200),
            alertStyle: .alarm,
            soundName: "Sosumi"))
        // Overdue and completed: the two states the row renders differently from a
        // plain future reminder, so both are in the PNGs rather than only in prose.
        store.upsertReminder(ReminderItem(
            title: "Send the compliance deck",
            dueDate: Date(timeIntervalSinceNow: -5_400),
            alertStyle: .notification,
            soundName: "Glass"))
        store.upsertReminder(ReminderItem(
            title: "Renew the developer certificate",
            dueDate: Date(timeIntervalSinceNow: -90_000),
            alertStyle: .notification,
            soundName: "Glass",
            isCompleted: true,
            completedAt: Date(timeIntervalSinceNow: -3_000)))
    }

    /// Feed the Insights dashboard believable history: several dictations a day
    /// across a handful of apps, spread over the last ~40 days with a few idle
    /// days poked out so the streak and heatmap read as real (not a solid block).
    private static func seedUsage(_ store: UsageStore) {
        // Mock data for rendering only — never let it touch a real per-account file.
        store.persistenceEnabled = false
        let engine = TranscriberEngine.slidingWindow.rawValue
        let apps: [(name: String, bundleID: String)] = [
            ("Slack", "com.tinyspeck.slackmacgap"),
            ("Safari", "com.apple.Safari"),
            ("Notes", "com.apple.Notes"),
            ("Xcode", "com.apple.dt.Xcode"),
            ("Messages", "com.apple.MobileSMS"),
        ]
        // Days we deliberately skip so the streak/heatmap aren't a solid wall.
        let idleDays: Set<Int> = [3, 4, 11, 18, 19, 27, 33, 34]
        // A deterministic pseudo-random walk keeps the snapshot stable run-to-run.
        var seed: UInt64 = 0x5DEE_CE66
        func next(_ upper: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(1, upper)))
        }

        for dayOffset in 0..<40 where !idleDays.contains(dayOffset) {
            let dictationsToday = 1 + next(4)   // 1…4 dictations per active day
            for _ in 0..<dictationsToday {
                let app = apps[next(apps.count)]
                let words = 10 + next(111)                      // 10…120 words
                let duration = 5 + Double(next(56))             // 5…60 seconds
                // Small hour/minute jitter so records land at different times of day.
                let secondsBack = Double(dayOffset) * 86_400 + Double(next(20)) * 3_600 + Double(next(60)) * 60
                let fixes = FixCounts(wordsCorrected: next(4), dictionary: next(3))
                store.record(DictationRecord(
                    timestamp: Date(timeIntervalSinceNow: -secondsBack),
                    wordCount: words,
                    durationSeconds: duration,
                    appName: app.name,
                    appBundleID: app.bundleID,
                    engineRawValue: engine,
                    fixes: fixes))
            }
        }
    }

    /// Renders one surface to `<name>.png`.
    ///
    /// The app is light-only, so there's a single appearance to cover — this used
    /// to render every surface twice (`-light`/`-dark`) back when the theme was
    /// dual-mode. The drawing appearance is still set explicitly rather than
    /// inherited: `performAsCurrentDrawingAppearance` is what any AppKit-backed
    /// colour resolves against, and the headless renderer has no window to take
    /// it from.
    /// The three layout directions for the finished turn, each drawn on a real notch
    /// band at its own natural width, so one can be chosen from a render. Delete this
    /// and `ReplyLayoutCandidates.swift` once a direction is picked.
    static func renderReplyCandidates(_ dir: URL) {
        renderCandidate(dir, name: "candidate-k-verdict", width: 860) {
            ReplyCandidateVerdict()
        }
        renderCandidate(dir, name: "candidate-l-plate", width: 800) {
            ReplyCandidatePlate()
        }
        renderCandidate(dir, name: "candidate-m-ruled", width: 880) {
            ReplyCandidateRuled()
        }
        renderCandidate(dir, name: "candidate-n-quiet", width: 900) {
            ReplyCandidateQuiet()
        }
    }

    private static func renderCandidate<V: View>(
        _ dir: URL, name: String, width: CGFloat, @ViewBuilder content: () -> V
    ) {
        let geometry = snapshotNotch
        let layout = NotchSurfaceLayout()
        let shape = NotchShape(
            topConcaveRadius: layout.topConcaveRadius,
            bottomCornerRadius: layout.bottomCornerRadius)
        let band = VStack(spacing: 0) {
            Color.clear.frame(height: geometry.notchHeight)
            content()
        }
        .frame(width: width)
        .background(shape.fill(Theme.Notch.surface))
        .clipShape(shape)

        let view = ZStack(alignment: .top) {
            Color(white: 0.28)
            band.padding(.horizontal, 46)
        }
        .frame(width: width + 92)
        render(view, to: dir.appendingPathComponent("\(name).png"))
    }

    private static func render<V: View>(_ view: V, to url: URL) {
        guard let appearance = NSAppearance(named: .aqua) else { return }

        var image: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.environment(\.isSnapshot, true))
            renderer.scale = 2
            image = renderer.nsImage
        }

        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("Failed to render \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
        print("Wrote \(url.lastPathComponent)")
    }
}
#endif
