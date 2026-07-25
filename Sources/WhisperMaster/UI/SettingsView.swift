import AppKit
import ClerkKit
import SwiftUI

/// The sections of the main window. The **primary** four (`today`, `notes`,
/// `connectors`, `settings`) are the sidebar nav, matching the Organic design;
/// the rest are **secondary** pages folded under Settings (reached from its
/// "More" list) so the sidebar stays to four items. `allCases` order is the
/// sidebar order for the primaries.
enum SettingsSection: String, CaseIterable, Identifiable {
    case today
    case notes
    case connectors
    case settings
    // Folded under Settings ("More"):
    case insights
    case engine
    case history
    case permissions
    case mesh
    case account
    case about

    var id: String { rawValue }

    /// The four items shown in the sidebar.
    static let primary: [SettingsSection] = [.today, .notes, .connectors, .settings]
    /// The pages folded into the Settings screen's "More" list.
    static let secondary: [SettingsSection] = [.insights, .engine, .history, .permissions, .mesh, .account, .about]

    var isPrimary: Bool { SettingsSection.primary.contains(self) }

    /// The sidebar item that should read as selected for this section (a
    /// secondary page highlights its parent, Settings).
    var sidebarParent: SettingsSection { isPrimary ? self : .settings }

    var title: String {
        switch self {
        case .today: return "Today"
        case .notes: return "Notes & Reminders"
        case .connectors: return "Connectors"
        case .settings: return "Settings"
        case .insights: return "Insights"
        case .engine: return "Voice engine"
        case .history: return "History"
        case .permissions: return "Permissions"
        case .mesh: return "Nearby Macs"
        case .account: return "Account"
        case .about: return "About"
        }
    }

    /// Compact label for the sidebar / "More" rows.
    var navLabel: String { title }

    var subtitle: String {
        switch self {
        case .today: return "Here's the shape of your day. Talk to me any time."
        case .notes: return "Jot notes and set reminders that follow you across your Macs."
        case .connectors: return "Link your calendar so Whisper can brief you and act on what you say."
        case .settings: return "Everything you can tune, in one warm place."
        case .insights: return "Your dictation at a glance — words, speed, and streaks."
        case .engine: return "Everything runs on-device. Your audio never leaves this Mac."
        case .history: return "Your recent transcriptions, kept locally."
        case .permissions: return "Whisper Master only asks for what it needs to work."
        case .mesh: return "Other Macs running Whisper Master on this Wi-Fi."
        case .account: return "You’re signed in. Sign out to lock the app."
        case .about: return "Voice dictation that stays on your Mac."
        }
    }

    var kicker: String {
        switch self {
        case .today: return "Your day"
        case .notes: return "Captured by voice"
        case .connectors: return "Integrations"
        case .settings: return "Preferences"
        case .insights: return "Overview"
        case .engine: return "On-device"
        case .history: return "Activity"
        case .permissions: return "Privacy"
        case .mesh: return "Mesh"
        case .account: return "You"
        case .about: return "Whisper Master"
        }
    }

    /// SF Symbol shown beside the title.
    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .notes: return "checklist"
        case .connectors: return "point.3.connected.trianglepath.dotted"
        case .settings: return "slider.horizontal.3"
        case .insights: return "chart.bar"
        case .engine: return "waveform"
        case .history: return "clock"
        case .permissions: return "lock.shield"
        case .mesh: return "laptopcomputer"
        case .account: return "person.crop.circle"
        case .about: return "info.circle"
        }
    }
}

/// The main window — "Organic": a warm, blurred ground with a floating
/// frosted-glass panel that holds a slim sidebar (brand, four nav pills, a mic
/// card and the account) beside a scrolling content pane.
struct SettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState
    var reopenOnboarding: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var startSetup: () -> Void = {}
    var cancelSetup: () -> Void = {}
    var signOut: () -> Void = {}
    var initialSection: SettingsSection = .today

    @State private var selection: SettingsSection
    @State private var hasAutoFocusedSetup = false
    @State private var micGranted = false
    @State private var micDenied = false
    @State private var accessibilityGranted = false
    @Environment(\.isSnapshot) private var isSnapshot
    private let permissions = PermissionsManager()

    init(
        viewModel: DictationViewModel,
        state: AppState,
        reopenOnboarding: @escaping () -> Void = {},
        checkForUpdates: @escaping () -> Void = {},
        startSetup: @escaping () -> Void = {},
        cancelSetup: @escaping () -> Void = {},
        signOut: @escaping () -> Void = {},
        initialSection: SettingsSection = .today
    ) {
        self.viewModel = viewModel
        _state = Bindable(wrappedValue: state)
        self.reopenOnboarding = reopenOnboarding
        self.checkForUpdates = checkForUpdates
        self.startSetup = startSetup
        self.cancelSetup = cancelSetup
        self.signOut = signOut
        self.initialSection = initialSection
        _selection = State(initialValue: initialSection)
    }

    var body: some View {
        ZStack {
            WarmBackground()

            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(Theme.stroke)
                    .frame(width: 1)
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassPanel(radius: 22)
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 16, trailing: 16))
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        .onAppear {
            refreshPermissions()
            autoFocusSetupIfNeeded()
            if let requested = state.requestedSettingsSection {
                selection = requested
                state.requestedSettingsSection = nil
            }
        }
        .onChange(of: state.requestedSettingsSection) { _, requested in
            guard let requested else { return }
            selection = requested
            state.requestedSettingsSection = nil
        }
        // Poll so a System Settings toggle (esp. Accessibility) shows up without
        // a relaunch; also refresh the instant we become active again after the
        // user flips the switch and returns to the app.
        .onReceive(Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()) { _ in
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand lockup — padded down to clear the native traffic-light buttons.
            HStack(spacing: 11) {
                BrandLogo(size: 34, cornerRadius: 11)
                Text("Whisper\nMaster")
                    .font(Typography.heading(17, relativeTo: .title3))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 34)
            .padding(.bottom, 24)

            VStack(spacing: 3) {
                ForEach(SettingsSection.primary) { section in
                    navRow(section)
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                SidebarMicCard(state: state, viewModel: viewModel)
                SidebarAccountRow(isSnapshot: isSnapshot)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .frame(width: 250)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.14))
    }

    private func navRow(_ section: SettingsSection) -> some View {
        let isSelected = selection.sidebarParent == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.textSecondary)
                    .frame(width: 22, alignment: .center)
                Text(section.navLabel)
                    .font(Typography.sans(14.5, isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous)
                        .fill(Color.white.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
                        )
                        .shadow(color: Theme.shadowRaised.color, radius: 6, x: 0, y: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if selection.isPrimary {
                    // Today renders its own greeting header; the other primaries
                    // use the shared kicker/title header.
                    if selection != .today {
                        header(selection)
                    }
                } else {
                    subPageHeader(selection)
                }

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
            .padding(.top, 34)
            .padding(.bottom, 48)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func header(_ section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            KickerLabel(section.kicker)
            Text(section.title)
                .font(Typography.largeTitle)
                .foregroundStyle(Theme.textPrimary)
            Text(section.subtitle)
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Header for a folded (secondary) page — adds a back affordance to Settings.
    private func subPageHeader(_ section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                selection = .settings
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    Text("Settings").font(Typography.caption)
                }
                .foregroundStyle(Theme.accentText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                KickerLabel(section.kicker)
                Text(section.title)
                    .font(Typography.largeTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text(section.subtitle)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selection {
        case .today:
            TodayView(viewModel: viewModel, state: state, openConnectors: { selection = .connectors })
        case .notes:
            NotesSettingsView(state: state)
        case .connectors:
            ConnectorsSettingsView(viewModel: viewModel, state: state)
        case .settings:
            GeneralSettingsView(viewModel: viewModel, state: state, openSubPage: { selection = $0 })
        case .engine:
            EngineSettingsView(viewModel: viewModel, state: state)
        case .mesh:
            MeshSettingsView(viewModel: viewModel, state: state)
        case .history:
            HistorySettingsView(viewModel: viewModel, state: state)
        case .insights:
            InsightsSettingsView(viewModel: viewModel, state: state)
        case .permissions:
            PermissionsSettingsView(
                permissions: permissions,
                micGranted: micGranted,
                micDenied: micDenied,
                accessibilityGranted: accessibilityGranted
            )
        case .account:
            AccountSettingsView(state: state, signOut: signOut)
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

// MARK: - Sidebar mic card

/// The sidebar's push-to-talk affordance: idle shows the ⌥ hint, recording
/// shows a pulsing "Listening…" state. Tapping toggles recording (the global
/// hotkey remains the primary trigger).
private struct SidebarMicCard: View {
    @Bindable var state: AppState
    let viewModel: DictationViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var isRecording: Bool { state.phase == .recording }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Color.white.opacity(0.22) : Theme.accent)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isRecording ? .white : Color(hex: 0xf5ead8))
                }
                .frame(width: 36, height: 36)
                .overlay {
                    if isRecording {
                        Circle()
                            .stroke(Theme.accent.opacity(0.55), lineWidth: 2)
                            .scaleEffect(pulse ? 1.5 : 1)
                            .opacity(pulse ? 0 : 0.8)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(isRecording ? "Listening…" : "Hold ⌥ to dictate")
                        .font(Typography.heading(13.5, relativeTo: .callout))
                        .foregroundStyle(isRecording ? .white : Theme.textPrimary)
                    Text(isRecording ? "Tap to stop" : "or tap to start")
                        .font(Typography.caption)
                        .foregroundStyle(isRecording ? Color.white.opacity(0.8) : Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(13)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isRecording ? Theme.accent : Color.white.opacity(0.42))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(isRecording ? Theme.Accent.n300.opacity(0.6) : Color.white.opacity(0.55), lineWidth: 1)
                    )
                    .shadow(color: Theme.shadowRaised.color, radius: 8, x: 0, y: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: isRecording)
        .onChange(of: isRecording) { _, rec in
            guard !reduceMotion else { return }
            pulse = false
            if rec { withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true } }
        }
        .accessibilityLabel(isRecording ? "Stop dictation" : "Start dictation")
    }

    private func toggle() {
        if isRecording { viewModel.stopRecording() } else { viewModel.startRecording() }
    }
}

// MARK: - Sidebar account row

/// The signed-in identity at the bottom of the sidebar. Snapshot-guarded so the
/// headless renderer (no Clerk environment) shows a stable stand-in.
private struct SidebarAccountRow: View {
    let isSnapshot: Bool

    var body: some View {
        if isSnapshot {
            AccountRowContent(name: "Alex Rivera", subtitle: "Pro · on-device", imageURL: nil)
        } else {
            LiveSidebarAccountRow()
        }
    }
}

private struct LiveSidebarAccountRow: View {
    @Environment(Clerk.self) private var clerk

    var body: some View {
        let user = clerk.user
        AccountRowContent(
            name: Self.displayName(user),
            subtitle: "on-device",
            imageURL: Self.imageURL(user)
        )
    }

    private static func displayName(_ user: User?) -> String {
        guard let user else { return "Signed in" }
        let name = [user.firstName, user.lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !name.isEmpty { return name }
        if let username = user.username, !username.isEmpty { return username }
        if let email = user.primaryEmailAddress?.emailAddress ?? user.emailAddresses.first?.emailAddress {
            return String(email.prefix(while: { $0 != "@" }))
        }
        return "Signed in"
    }

    private static func imageURL(_ user: User?) -> URL? {
        guard let user, user.hasImage, !user.imageUrl.isEmpty else { return nil }
        return URL(string: user.imageUrl)
    }
}

private struct AccountRowContent: View {
    let name: String
    let subtitle: String
    var imageURL: URL?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let imageURL {
                    AsyncImage(url: imageURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else { initials }
                    }
                } else {
                    initials
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(Typography.sans(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var initials: some View {
        ZStack {
            Circle().fill(Theme.accent2)
            Text(initialsText)
                .font(Typography.sans(12, .bold))
                .foregroundStyle(.white)
        }
    }

    private var initialsText: String {
        let parts = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }
        let joined = parts.joined().uppercased()
        return joined.isEmpty ? "?" : joined
    }
}
