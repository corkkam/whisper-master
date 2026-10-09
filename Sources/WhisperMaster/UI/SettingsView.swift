import AppKit
import SwiftUI

/// The four primary screens of the main window, shown as sidebar destinations in
/// the Organic shell.
enum SettingsSection: String, CaseIterable, Identifiable {
    case today
    case notes
    case connectors
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .notes: return "Notes & Reminders"
        case .connectors: return "Connectors"
        case .settings: return "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .today: return "Your agenda and to-dos at a glance."
        case .notes: return "Everything you've dictated, kept on this Mac."
        case .connectors: return "Where Whisper Master can send your voice."
        case .settings: return "How dictation behaves, and everything else."
        }
    }

    var kicker: String {
        switch self {
        case .today: return "Your day"
        case .notes: return "Captured"
        case .connectors: return "Reach"
        case .settings: return "Preferences"
        }
    }

    /// SF Symbol shown in the sidebar nav.
    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .notes: return "note.text"
        case .connectors: return "square.grid.2x2"
        case .settings: return "gearshape"
        }
    }
}

/// The seven sections folded into the Settings screen as push-navigable
/// sub-pages (the design's 4-item sidebar absorbed the rest).
enum SettingsSubPage: String, CaseIterable, Identifiable {
    case engine
    case insights
    case history
    case permissions
    case mesh
    case account
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .engine: return "Voice engine"
        case .insights: return "Insights"
        case .history: return "History"
        case .permissions: return "Permissions"
        case .mesh: return "Nearby Macs"
        case .account: return "Account"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .engine: return "Everything runs on-device. Your audio never leaves this Mac."
        case .insights: return "What you've dictated, by the numbers."
        case .history: return "Your recent transcriptions, kept locally."
        case .permissions: return "Whisper Master only asks for what it needs to work."
        case .mesh: return "Other Macs running Whisper Master on this Wi-Fi."
        case .account: return "Who you're signed in as."
        case .about: return "Voice dictation that stays on your Mac."
        }
    }

    var icon: String {
        switch self {
        case .engine: return "waveform"
        case .insights: return "chart.bar"
        case .history: return "clock"
        case .permissions: return "shield"
        case .mesh: return "laptopcomputer"
        case .account: return "person.crop.circle"
        case .about: return "info.circle"
        }
    }
}

/// The main window — the Organic shell: a warm blob-gradient ground, an inset
/// frosted-glass panel holding a glass-pill sidebar (brand lockup + nav + mic
/// card + account row) and a scrolling detail column.
struct SettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState
    let notes: NotesStore
    let connectors: ConnectorStore
    @Bindable var account: AccountStore
    var reopenOnboarding: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var startSetup: () -> Void = {}
    var cancelSetup: () -> Void = {}
    var initialSection: SettingsSection = .today

    @State private var selection: SettingsSection
    @State private var subPage: SettingsSubPage?
    @State private var hasAutoFocusedSetup = false
    @State private var micGranted = false
    @State private var micDenied = false
    @State private var accessibilityGranted = false
    private let permissions = PermissionsManager()

    init(
        viewModel: DictationViewModel,
        state: AppState,
        notes: NotesStore,
        connectors: ConnectorStore,
        account: AccountStore,
        reopenOnboarding: @escaping () -> Void = {},
        checkForUpdates: @escaping () -> Void = {},
        startSetup: @escaping () -> Void = {},
        cancelSetup: @escaping () -> Void = {},
        initialSection: SettingsSection = .today
    ) {
        self.viewModel = viewModel
        _state = Bindable(wrappedValue: state)
        self.notes = notes
        self.connectors = connectors
        _account = Bindable(wrappedValue: account)
        self.reopenOnboarding = reopenOnboarding
        self.checkForUpdates = checkForUpdates
        self.startSetup = startSetup
        self.cancelSetup = cancelSetup
        self.initialSection = initialSection
        _selection = State(initialValue: initialSection)
    }

    var body: some View {
        ZStack {
            WarmBackground()
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(Theme.stroke).frame(width: 1)
                detail
            }
            .glassPanel(cornerRadius: Theme.panelRadius)
            .padding(18)
        }
        .frame(minWidth: 860, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        .onAppear {
            refreshPermissions()
            autoFocusSetupIfNeeded()
        }
        .onChange(of: selection) { _, _ in subPage = nil }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            refreshPermissions()
            connectors.refresh()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandLogo(size: 34, cornerRadius: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Whisper Master")
                        .font(Typography.display(18))
                        .foregroundStyle(Theme.textPrimary)
                    Text("On-device dictation")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 28)
            .padding(.bottom, 26)

            VStack(spacing: 6) {
                ForEach(SettingsSection.allCases) { section in
                    navRow(section)
                }
            }
            .padding(.horizontal, 14)

            Spacer(minLength: 16)

            MicCard(state: state) {
                if state.phase == .recording {
                    viewModel.stopRecording()
                } else {
                    viewModel.startRecording()
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            accountRow
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
        }
        .frame(width: 268)
        .frame(maxHeight: .infinity)
    }

    private func navRow(_ section: SettingsSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 22, alignment: .center)
                Text(section.title)
                    .font(Typography.sans(15, isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
                        )
                        .shadow(color: Theme.softShadow, radius: 6, x: 0, y: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var accountRow: some View {
        Button {
            selection = .settings
            subPage = .account
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(Theme.accent)
                    Text(account.initials)
                        .font(Typography.sans(13, .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayName)
                        .font(Typography.sans(13.5, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(account.planLabel)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.32))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if shouldShowSetupBanner, selection == .today || (selection == .settings && subPage == nil) {
                    SetupBanner(
                        state: state,
                        startSetup: startSetup,
                        cancelSetup: cancelSetup,
                        openEngine: { selection = .settings; subPage = .engine }
                    )
                }
                panelContent
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 52)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selection {
        case .today:
            TodayView(
                state: state,
                notes: notes,
                connectors: connectors,
                account: account,
                startTalking: { viewModel.startRecording() },
                openConnectors: { selection = .connectors },
                openNotes: { selection = .notes }
            )
        case .notes:
            sectionHeader(selection.kicker, selection.title, selection.subtitle)
            NotesSettingsView(notes: notes, viewModel: viewModel)
        case .connectors:
            sectionHeader(selection.kicker, selection.title, selection.subtitle)
            ConnectorsSettingsView(connectors: connectors)
        case .settings:
            settingsPanel
        }
    }

    @ViewBuilder
    private var settingsPanel: some View {
        if let subPage {
            subPageHeader(subPage)
            subPageContent(subPage)
        } else {
            sectionHeader(selection.kicker, selection.title, selection.subtitle)
            RecordingSettingsView(viewModel: viewModel, state: state)
            MoreSettingsList { subPage = $0 }
        }
    }

    @ViewBuilder
    private func subPageContent(_ page: SettingsSubPage) -> some View {
        switch page {
        case .engine:
            EngineSettingsView(viewModel: viewModel, state: state)
        case .insights:
            InsightsSettingsView(state: state)
        case .history:
            HistorySettingsView(viewModel: viewModel, state: state)
        case .permissions:
            PermissionsSettingsView(
                permissions: permissions,
                micGranted: micGranted,
                micDenied: micDenied,
                accessibilityGranted: accessibilityGranted
            )
        case .mesh:
            MeshSettingsView(viewModel: viewModel, state: state)
        case .account:
            AccountSettingsView(account: account)
        case .about:
            AboutSettingsView(state: state, reopenOnboarding: reopenOnboarding, checkForUpdates: checkForUpdates)
        }
    }

    // MARK: - Headers

    private func sectionHeader(_ kicker: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                KickerLabel(kicker)
                Text(title)
                    .font(Typography.largeTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 16)
            if state.phase == .recording {
                RecordingLevelBadge(level: state.audioLevel)
            }
        }
    }

    private func subPageHeader(_ page: SettingsSubPage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                subPage = nil
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Settings").font(Typography.bodyMedium)
                }
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text(page.title)
                    .font(Typography.largeTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text(page.subtitle)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Setup banner gate

    private var shouldShowSetupBanner: Bool {
        if state.preparingEngine != nil { return true }
        return !state.selectedEngine.isInstalled
    }

    // MARK: - Helpers

    private func autoFocusSetupIfNeeded() {
        guard !hasAutoFocusedSetup else { return }
        hasAutoFocusedSetup = true
        if !state.selectedEngine.isInstalled || state.preparingEngine != nil {
            selection = .settings
            subPage = .engine
        }
    }

    private func refreshPermissions() {
        let micStatus = permissions.microphoneStatus()
        micGranted = micStatus == .granted
        micDenied = micStatus == .denied
        accessibilityGranted = permissions.accessibilityGranted()
    }
}

/// The "More" list on the Settings root — push-nav rows to the folded sub-pages.
private struct MoreSettingsList: View {
    let open: (SettingsSubPage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("More")
            VStack(spacing: 0) {
                ForEach(Array(SettingsSubPage.allCases.enumerated()), id: \.element.id) { index, page in
                    Button { open(page) } label: {
                        HStack(spacing: 13) {
                            Image(systemName: page.icon)
                                .font(.system(size: 15, weight: .regular))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(page.title)
                                    .font(Typography.headline)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(page.subtitle)
                                    .font(Typography.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < SettingsSubPage.allCases.count - 1 {
                        RowDivider()
                    }
                }
            }
            .padding(.horizontal, 20)
            .glassCard()
        }
    }
}

/// The sidebar mic card — Hold-⌥ idle prompt, or a live "Listening…" state with
/// an audio-level meter. Tapping toggles recording.
private struct MicCard: View {
    @Bindable var state: AppState
    let toggle: () -> Void

    private var isRecording: Bool { state.phase == .recording }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Theme.accent : Color.white.opacity(0.5))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
                    Image(systemName: isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isRecording ? .white : Theme.accent)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isRecording ? "Listening…" : "Hold \(state.hotkey.compactName) to talk")
                        .font(Typography.sans(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if isRecording {
                        MicLevelBar(level: state.audioLevel)
                    } else {
                        Text("or click to start")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .glassCard(cornerRadius: 16, tint: 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A slim live level meter for the mic card.
private struct MicLevelBar: View {
    let level: Float
    private let barCount = 16

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(i < activeBars ? Theme.accent : Theme.textTertiary.opacity(0.35))
                    .frame(width: 2, height: barHeight(i))
            }
        }
        .frame(height: 12, alignment: .center)
    }

    private var activeBars: Int {
        Int(Double(min(1, max(0, level * 8))) * Double(barCount))
    }

    private func barHeight(_ i: Int) -> CGFloat {
        4 + abs(sin(Double(i) * 0.7)) * 8
    }
}

/// A compact live input-level meter shown in a section header while recording.
struct RecordingLevelBadge: View {
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
        .glassCard(cornerRadius: 12)
    }

    private var activeBars: Int {
        Int(Double(min(1, max(0, level * 8))) * Double(barCount))
    }

    private func barHeight(_ i: Int) -> CGFloat {
        4 + abs(sin(Double(i) * 0.7)) * 12
    }
}
