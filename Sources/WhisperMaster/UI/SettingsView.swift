import AppKit
import SwiftUI

/// The five sections of the settings window, shown in the sidebar.
enum SettingsSection: String, CaseIterable, Identifiable {
    case recording
    case engine
    case history
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: return "Recording"
        case .engine: return "Voice engine"
        case .history: return "History"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .recording: return "mic.fill"
        case .engine: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .recording: return "How dictation starts, stops, and lands where you're typing."
        case .engine: return "Everything runs on-device — your audio never leaves this Mac."
        case .history: return "Your recent transcriptions, kept locally."
        case .permissions: return "Whisper Master only asks for what it needs to work."
        case .about: return "Voice dictation that stays on your Mac."
        }
    }

    var kicker: String {
        switch self {
        case .recording: return "Capture"
        case .engine: return "On-device"
        case .history: return "Activity"
        case .permissions: return "Privacy"
        case .about: return "Whisper Master"
        }
    }
}

/// The settings window: a slim shell that owns navigation + cross-cutting state
/// (permissions polling, the setup banner) and routes to a focused view per
/// section. The per-section views live in `UI/Settings/`.
struct SettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState
    var reopenOnboarding: () -> Void = {}
    var startSetup: () -> Void = {}
    var cancelSetup: () -> Void = {}
    /// Initial section to show. Defaults to recording; overridable so snapshot
    /// tooling can render each panel.
    var initialSection: SettingsSection = .recording

    @State private var selection: SettingsSection

    init(
        viewModel: DictationViewModel,
        state: AppState,
        reopenOnboarding: @escaping () -> Void = {},
        startSetup: @escaping () -> Void = {},
        cancelSetup: @escaping () -> Void = {},
        initialSection: SettingsSection = .recording
    ) {
        self.viewModel = viewModel
        _state = Bindable(wrappedValue: state)
        self.reopenOnboarding = reopenOnboarding
        self.startSetup = startSetup
        self.cancelSetup = cancelSetup
        self.initialSection = initialSection
        _selection = State(initialValue: initialSection)
    }
    @State private var hasAutoFocusedSetup = false
    @State private var micGranted = false
    @State private var micDenied = false
    @State private var accessibilityGranted = false
    private let permissions = PermissionsManager()

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                selection: $selection,
                state: state,
                permissionsReady: micGranted && accessibilityGranted
            )
            detail
        }
        .frame(minWidth: 840, minHeight: 600)
        .background(Theme.canvas)
        .onAppear {
            refreshPermissions()
            autoFocusSetupIfNeeded()
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            refreshPermissions()
        }
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                detailHeader

                if shouldShowSetupBanner, selection != .engine {
                    SetupBanner(
                        state: state,
                        startSetup: startSetup,
                        cancelSetup: cancelSetup,
                        openEngine: { selection = .engine }
                    )
                }

                panelContent
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 44)
            .padding(.vertical, 40)
        }
        .background(Theme.canvasGradient)
    }

    private var detailHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                KickerLabel(selection.kicker)
                Text(selection.title)
                    .font(Typography.largeTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text(selection.subtitle)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 16)
            if state.phase == .recording {
                RecordingLevelBadge(level: state.audioLevel)
            }
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selection {
        case .recording:
            RecordingSettingsView(viewModel: viewModel, state: state)
        case .engine:
            EngineSettingsView(viewModel: viewModel, state: state)
        case .history:
            HistorySettingsView(viewModel: viewModel, state: state)
        case .permissions:
            PermissionsSettingsView(
                permissions: permissions,
                micGranted: micGranted,
                micDenied: micDenied,
                accessibilityGranted: accessibilityGranted
            )
        case .about:
            AboutSettingsView(state: state, reopenOnboarding: reopenOnboarding)
        }
    }

    // MARK: - Setup banner gate

    private var shouldShowSetupBanner: Bool {
        if state.preparingEngine != nil { return true }
        if case .failed = state.phase { return !state.selectedEngine.isInstalled }
        return !state.selectedEngine.isInstalled
    }

    // MARK: - Helpers

    private func autoFocusSetupIfNeeded() {
        guard !hasAutoFocusedSetup else { return }
        hasAutoFocusedSetup = true
        if !state.selectedEngine.isInstalled || state.preparingEngine != nil {
            selection = .engine
        }
    }

    private func refreshPermissions() {
        let micStatus = permissions.microphoneStatus()
        micGranted = micStatus == .granted
        micDenied = micStatus == .denied
        accessibilityGranted = permissions.accessibilityGranted()
    }
}

/// A compact live input-level meter shown in the header while recording.
private struct RecordingLevelBadge: View {
    let level: Float
    private let barCount = 14

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(i < activeBars ? Theme.accent : Theme.textTertiary.opacity(0.4))
                        .frame(width: 2.5, height: barHeight(i))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1)
        )
    }

    private var activeBars: Int {
        Int(Double(min(1, max(0, level * 8))) * Double(barCount))
    }

    private func barHeight(_ i: Int) -> CGFloat {
        4 + abs(sin(Double(i) * 0.7)) * 12
    }
}
