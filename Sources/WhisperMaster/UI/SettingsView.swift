import AppKit
import SwiftUI

/// The five sections of the settings window, shown as top tabs.
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

    /// Short label for the tab bar.
    var tab: String {
        switch self {
        case .recording: return "Recording"
        case .engine: return "Engine"
        case .history: return "History"
        case .permissions: return "Permissions"
        case .about: return "About"
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

/// The settings window — "Daylight": a light, editorial layout with a top tab
/// bar (no sidebar) and a centered, hairline-ruled content column.
struct SettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState
    var reopenOnboarding: () -> Void = {}
    var startSetup: () -> Void = {}
    var cancelSetup: () -> Void = {}
    var initialSection: SettingsSection = .recording

    @State private var selection: SettingsSection
    @State private var hasAutoFocusedSetup = false
    @State private var micGranted = false
    @State private var micDenied = false
    @State private var accessibilityGranted = false
    private let permissions = PermissionsManager()

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

    var body: some View {
        VStack(spacing: 0) {
            masthead
            detail
        }
        .frame(minWidth: 720, minHeight: 600)
        .background(Theme.canvasGradient)
        .onAppear {
            refreshPermissions()
            autoFocusSetupIfNeeded()
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            refreshPermissions()
        }
    }

    // MARK: - Masthead (brand + status + tabs)

    private var masthead: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BrandLogo(size: 26, cornerRadius: 7)
                Text("Whisper Master")
                    .font(Typography.optima(17, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                statusPill
            }
            .padding(.leading, 80)   // clear the traffic-light buttons
            .padding(.trailing, 24)
            .padding(.top, 16)
            .padding(.bottom, 14)

            HStack(spacing: 26) {
                ForEach(SettingsSection.allCases) { section in
                    tab(section)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)

            Rectangle().fill(Theme.stroke).frame(height: 1)
                .padding(.top, 12)
        }
    }

    private func tab(_ section: SettingsSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            VStack(spacing: 8) {
                Text(section.tab)
                    .font(Typography.optima(14, isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                Rectangle()
                    .fill(isSelected ? Theme.accent : Color.clear)
                    .frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            StatusDot(color: statusColor, size: 7)
            Text(statusLabel)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

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
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 40)
            .padding(.top, 34)
            .padding(.bottom, 52)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
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

    private var permissionsReady: Bool { micGranted && accessibilityGranted }

    private var statusColor: Color {
        switch state.phase {
        case .recording, .preparingModels, .failed:
            return Theme.accent
        case .idle, .stopping:
            return permissionsReady ? Theme.success : Theme.textTertiary
        }
    }

    private var statusLabel: String {
        switch state.phase {
        case .recording: return "Recording"
        case .preparingModels: return "Preparing"
        case .stopping: return "Finalizing"
        case .failed: return "Error"
        case .idle:
            return permissionsReady ? "Ready · \(state.hotkey.compactName)" : "Needs setup"
        }
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
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    private var activeBars: Int {
        Int(Double(min(1, max(0, level * 8))) * Double(barCount))
    }

    private func barHeight(_ i: Int) -> CGFloat {
        4 + abs(sin(Double(i) * 0.7)) * 12
    }
}
