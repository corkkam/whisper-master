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
        for section in [SettingsSection.recording, .history, .engine] {
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

        print("Snapshots written to \(dir.path)")
        exit(0)
    }

    @ViewBuilder
    private static func sectionView(_ section: SettingsSection, viewModel: DictationViewModel, state: AppState) -> some View {
        switch section {
        case .recording: RecordingSettingsView(viewModel: viewModel, state: state)
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
