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

        // Onboarding steps.
        for step in OnboardingStep.allCases {
            let onboarding = OnboardingView(
                state: state,
                permissions: PermissionsManager(),
                microphoneCapture: MicrophoneCaptureService(),
                retryEngine: {},
                onClose: {},
                onComplete: {},
                initialStep: step
            )
            .frame(width: 640, height: 580)
            render(onboarding, to: dir.appendingPathComponent("onboarding-\(step.rawValue)-\(step.title.lowercased().replacingOccurrences(of: " ", with: "")).png"))
        }

        // Notch pill / moment-of-truth states. The dark surface is rendered on a
        // neutral backdrop so the black band reads. Each state uses its own fresh
        // AppState so the fields don't bleed across renders.
        renderPill(dir, name: "pill-1-listening") { s in
            s.phase = .recording
            s.audioLevel = 0.42
        }
        renderPill(dir, name: "pill-2-finalizing") { s in
            s.phase = .stopping
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
            s.undeliveredTranscriptAt = Date()
        }
        renderPill(dir, name: "pill-6-bluetooth") { s in
            s.phase = .idle
            s.bluetoothInputActive = true
        }

        print("Snapshots written to \(dir.path)")
        exit(0)
    }

    /// Render the notch pill in a single state onto a neutral backdrop.
    private static func renderPill(_ dir: URL, name: String, configure: (AppState) -> Void) {
        let state = AppState()
        state.hidePillWhenIdle = false
        configure(state)
        let view = ZStack(alignment: .top) {
            Color(white: 0.28)
            DictationPillContent(state: state, geometry: .none)
                .frame(width: 428, height: 90, alignment: .top)
        }
        .frame(width: 520, height: 150)
        render(view, to: dir.appendingPathComponent("\(name).png"))
    }

    @ViewBuilder
    private static func sectionView(_ section: SettingsSection, viewModel: DictationViewModel, state: AppState) -> some View {
        switch section {
        case .insights: InsightsSettingsView(viewModel: viewModel, state: state)
        case .notes: NotesSettingsView(state: state)
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
                Text(section.title).font(Typography.largeTitle).foregroundStyle(Theme.textPrimary)
                Text(section.subtitle).font(Typography.body).foregroundStyle(Theme.textSecondary)
            }
            sectionView(section, viewModel: viewModel, state: state)
        }
        .frame(width: 680, alignment: .leading)
        .padding(.horizontal, 44)
        .padding(.vertical, 40)
        .frame(width: 768, alignment: .topLeading)
        .background(Theme.canvasGradient)
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
        seedUsage(state.usageStore)
        seedNotes(state.notesStore)
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

    private static func render<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.isSnapshot, true))
        renderer.scale = 2
        guard let image = renderer.nsImage,
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
