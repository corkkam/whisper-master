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

        // Each section's panel on its own (ImageRenderer collapses flexible
        // ScrollViews, so we render the fixed detail container instead).
        for section in SettingsSection.allCases {
            render(
                detailContainer(section: section, viewModel: viewModel, state: state),
                to: dir.appendingPathComponent("panel-\(section.rawValue).png")
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
        notchWidth: 208, notchHeight: 37.5, screenWidth: 1710
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
    private static func sectionView(_ section: SettingsSection, viewModel: DictationViewModel, state: AppState) -> some View {
        switch section {
        case .today: TodayView(viewModel: viewModel, state: state)
        case .insights: InsightsSettingsView(viewModel: viewModel, state: state)
        case .notes: NotesSettingsView(state: state)
        case .connectors: ConnectorsSettingsView(viewModel: viewModel, state: state)
        case .settings: GeneralSettingsView(viewModel: viewModel, state: state)
        case .engine: EngineSettingsView(viewModel: viewModel, state: state)
        case .mesh: MeshSettingsView(viewModel: viewModel, state: state)
        case .history: HistorySettingsView(viewModel: viewModel, state: state)
        case .permissions:
            PermissionsSettingsView(permissions: PermissionsManager(), micGranted: true, micDenied: false, accessibilityGranted: false)
        case .about: AboutSettingsView(state: state)
        }
    }

    private static func detailContainer(section: SettingsSection, viewModel: DictationViewModel, state: AppState) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 7) {
                KickerLabel(section.kicker)
                Text(section.title).font(Typography.largeTitle).tracking(Typography.largeTitleTracking).foregroundStyle(Theme.textPrimary)
                Text(section.subtitle).font(Typography.body).foregroundStyle(Theme.textSecondary)
            }
            sectionView(section, viewModel: viewModel, state: state)
        }
        .frame(width: 680, alignment: .leading)
        .padding(.horizontal, 44)
        .padding(.vertical, 40)
        .frame(width: 768, alignment: .topLeading)
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
                question: "Morning briefing",
                answer: "Two things need you today: the release notes, and Friday's demo script.",
                askedAt: Date(timeIntervalSinceNow: -9000),
                source: .automation),
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
        // The assistant, one standing permission and one automation, so the whole
        // Connectors page renders headlessly rather than only its top half.
        state.connectorAgentEnabled = true
        state.cleanupModelReady = true
        let mockSlack = state.connectorStore.add(ConnectorInstance(
            kind: .slack, label: "Work chat", identity: "Acme / whisper"))
        state.connectorStore.addGrant(
            Grant(tool: "send_message", instanceID: mockSlack.id, target: "#standup"))
        state.automationStore.persistenceEnabled = false
        state.automationStore.add(ScheduledTask(
            title: "Morning briefing",
            instructions: "what's on my work calendar today",
            schedule: .daily(hour: 8, minute: 30)))
    }

    /// A couple of believable notes + reminders so the Notes & Reminders panel
    /// renders with real-looking content (never touches a real per-account file).
    private static func seedNotes(_ store: NotesStore) {
        store.persistenceEnabled = false
        store.upsertNote(Note(
            title: "Demo script",
            body: "Open with the notch pill, then dictate into Slack to show live paste."))
        store.upsertNote(Note(
            title: "Follow-ups",
            body: "Ping design about the Daylight tokens; sync FluidAudio version."))
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

    /// Renders each surface **twice**, once per appearance, as `<name>-light.png`
    /// and `<name>-dark.png`. Since the theme became dual-mode, a single-mode
    /// snapshot only covers half the regression surface.
    ///
    /// Two things have to agree for the tokens to resolve correctly: SwiftUI's
    /// `colorScheme` environment (read by the glass recipes) and AppKit's
    /// current drawing appearance (read by the dynamic `NSColor` providers
    /// behind every token). Setting only one of them silently renders a mixed
    /// palette.
    private static func render<V: View>(_ view: V, to url: URL) {
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let name = url.deletingPathExtension().lastPathComponent
            let target = url
                .deletingLastPathComponent()
                .appendingPathComponent("\(name)-\(suffix).png")

            guard let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) else { continue }

            var image: NSImage?
            appearance.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(
                    content: view
                        .environment(\.isSnapshot, true)
                        .environment(\.colorScheme, scheme)
                )
                renderer.scale = 2
                image = renderer.nsImage
            }

            guard let image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("Failed to render \(target.lastPathComponent)")
                continue
            }
            try? png.write(to: target)
            print("Wrote \(target.lastPathComponent)")
        }
    }
}
#endif
