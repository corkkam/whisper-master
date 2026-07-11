import AppKit
import SwiftUI

/// The five sections of the settings window, shown as top tabs.
enum SettingsSection: String, CaseIterable, Identifiable {
    case insights
    case recording
    case engine
    case mesh
    case history
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insights: return "Insights"
        case .recording: return "Recording"
        case .engine: return "Voice engine"
        case .mesh: return "Nearby Macs"
        case .history: return "History"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    /// Short label for the tab bar.
    var tab: String {
        switch self {
        case .insights: return "Insights"
        case .recording: return "Recording"
        case .engine: return "Engine"
        case .mesh: return "Mesh"
        case .history: return "History"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .insights: return "Your dictation at a glance — words, speed, and streaks."
        case .recording: return "How dictation starts, stops, and lands where you're typing."
        case .engine: return "Everything runs on-device. Your audio never leaves this Mac."
        case .mesh: return "Other Macs running Whisper Master on this Wi-Fi."
        case .history: return "Your recent transcriptions, kept locally."
        case .permissions: return "Whisper Master only asks for what it needs to work."
        case .about: return "Voice dictation that stays on your Mac."
        }
    }

    var kicker: String {
        switch self {
        case .insights: return "Overview"
        case .recording: return "Capture"
        case .engine: return "On-device"
        case .mesh: return "Mesh"
        case .history: return "Activity"
        case .permissions: return "Privacy"
        case .about: return "Whisper Master"
        }
    }

    /// SF Symbol shown beside the title in the sidebar.
    var icon: String {
        switch self {
        case .insights: return "chart.bar"
        case .recording: return "mic"
        case .engine: return "waveform"
        case .mesh: return "laptopcomputer"
        case .history: return "clock"
        case .permissions: return "shield"
        case .about: return "info.circle"
        }
    }
}

/// The settings window — "Daylight": a light, editorial layout with a top tab
/// bar (no sidebar) and a centered, hairline-ruled content column.
struct SettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState
    var reopenOnboarding: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var startSetup: () -> Void = {}
    var cancelSetup: () -> Void = {}
    var initialSection: SettingsSection = .insights

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
        checkForUpdates: @escaping () -> Void = {},
        startSetup: @escaping () -> Void = {},
        cancelSetup: @escaping () -> Void = {},
        initialSection: SettingsSection = .insights
    ) {
        self.viewModel = viewModel
        _state = Bindable(wrappedValue: state)
        self.reopenOnboarding = reopenOnboarding
        self.checkForUpdates = checkForUpdates
        self.startSetup = startSetup
        self.cancelSetup = cancelSetup
        self.initialSection = initialSection
        _selection = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            nav
            sectionSeparator
            detail
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .background(Theme.canvasGradient.ignoresSafeArea())
        .onAppear {
            refreshPermissions()
            autoFocusSetupIfNeeded()
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            refreshPermissions()
        }
    }

    // MARK: - Sidebar (vertical nav)

    private var nav: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandLogo(size: 32, cornerRadius: 8)
                Text("Whisper Master")
                    .font(Typography.sans(18, .bold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 32)
            .padding(.bottom, 30)

            VStack(spacing: 0) {
                ForEach(SettingsSection.allCases) { section in
                    navRow(section)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: 252)
        .frame(maxHeight: .infinity)
    }

    /// Double-rule seam between the sidebar and the content: two lines with a
    /// small gap and a soft shadow falling onto the content for a bit of depth.
    private var sectionSeparator: some View {
        HStack(spacing: 4) {
            Rectangle().fill(Theme.strokeStrong).frame(width: 2)
            Rectangle().fill(Theme.stroke).frame(width: 2)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.canvas)
        .shadow(color: .black.opacity(0.08), radius: 5, x: 2, y: 0)
        .zIndex(1)
    }

    private func navRow(_ section: SettingsSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 13) {
                Image(systemName: section.icon)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 22, alignment: .center)
                Text(section.title)
                    .font(Typography.sans(16.5, isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.selection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)   // inset the pill from the sidebar edges
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
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 52)
            // Cap the reading column and center it, while the scroll view itself
            // fills the pane — so on wide/fullscreen the content stays balanced
            // and the scrollbar stays at the window's right edge (nothing empty
            // to the right of it).
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
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
        case .insights:
            InsightsSettingsView(viewModel: viewModel, state: state)
        case .recording:
            RecordingSettingsView(viewModel: viewModel, state: state)
        case .engine:
            EngineSettingsView(viewModel: viewModel, state: state)
        case .mesh:
            MeshSettingsView(viewModel: viewModel, state: state)
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
            AboutSettingsView(state: state, reopenOnboarding: reopenOnboarding, checkForUpdates: checkForUpdates)
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
