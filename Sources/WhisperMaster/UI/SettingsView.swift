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
    case about

    var id: String { rawValue }

    /// The four items shown in the sidebar.
    static let primary: [SettingsSection] = [.today, .notes, .connectors, .settings]
    /// The pages folded into the Settings screen's "More" list.
    static let secondary: [SettingsSection] = [.insights, .engine, .history, .permissions, .mesh, .about]

    var isPrimary: Bool { SettingsSection.primary.contains(self) }

    /// Whether this section can be opened, given whether the Connectors/Notes
    /// feature set has shipped. Pure, so the gate is unit-testable for both
    /// channels without a bundle.
    func isAvailable(connectorsAndNotes: Bool) -> Bool {
        switch self {
        case .notes, .connectors: return connectorsAndNotes
        default: return true
        }
    }

    /// Whether this section can be opened in *this* build.
    ///
    /// Connectors and Notes & Reminders are not yet released on stable (see
    /// `FeatureFlags`) — they stay listed in the sidebar but read "Coming soon"
    /// and don't respond. Everything else is always available.
    var isAvailable: Bool {
        isAvailable(connectorsAndNotes: FeatureFlags.connectorsAndNotesAvailable)
    }

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
        case .about: return "About"
        }
    }

    /// Compact label for the sidebar / "More" rows.
    ///
    /// Notes shortens here: the 250pt sidebar can't fit "Notes & Reminders"
    /// alongside the "Soon" tag without truncating mid-word, and a clipped label
    /// reads as a bug. The page itself still carries the full `title`.
    var navLabel: String {
        switch self {
        case .notes: return "Notes"
        default: return title
        }
    }

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
        _selection = State(initialValue: initialSection.isAvailable ? initialSection : .today)
    }

    /// Never land on a section this build hasn't released — fall back to Today.
    /// Every external navigation request funnels through here (the notch's
    /// "reminder set" tap, `state.requestedSettingsSection`, `initialSection`).
    private func select(_ section: SettingsSection) {
        selection = section.isAvailable ? section : .today
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
                select(requested)
                state.requestedSettingsSection = nil
            }
        }
        .onChange(of: state.requestedSettingsSection) { _, requested in
            guard let requested else { return }
            select(requested)
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
                SidebarAccountRow(isSnapshot: isSnapshot, signOut: signOut)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .frame(width: 250)
        .frame(maxHeight: .infinity)
        .background(Theme.surfaceGlass)
    }

    private func navRow(_ section: SettingsSection) -> some View {
        // An unreleased section reads as a roadmap row, not a broken button: it
        // never selects, dims to tertiary ink, and carries a "Soon" tag. The
        // Button is still what renders it so the row's metrics don't shift.
        let isAvailable = section.isAvailable
        let isSelected = isAvailable && selection.sidebarParent == section
        return Button {
            guard isAvailable else { return }
            selection = section
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accentText
                                     : isAvailable ? Theme.textSecondary : Theme.textTertiary)
                    .frame(width: 22, alignment: .center)
                Text(section.navLabel)
                    .font(Typography.sans(14.5, isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.accentText
                                     : isAvailable ? Theme.textSecondary : Theme.textTertiary)
                    // The "Soon" tag competes for the row's width, and without
                    // these "Notes & Reminders" wraps to two lines and that row
                    // grows taller than its neighbours. The label wins the space;
                    // the tag is fixed-width and never wraps.
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if !isAvailable {
                    Text("Soon")
                        .font(Typography.sans(10.5, .bold))
                        .tracking(0.4)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous).fill(Theme.textTertiary.opacity(0.12))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                if isSelected {
                    // Selection is an accent-tinted glow, never a brighter
                    // border — a bright slab is the system's anti-pattern.
                    RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous)
                        .fill(Theme.accentSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.22), lineWidth: 1)
                        )
                        .shadow(color: Theme.Ember.base.opacity(0.22), radius: 14, x: 0, y: 5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isAvailable ? section.navLabel : "\(section.navLabel), coming soon")
        // `.pointerCursor()` reads `\.isEnabled` itself, so it has to sit inside
        // `.disabled(…)` — environment only flows down. Applied outside, an
        // unreleased row would still show the hand.
        .pointerCursor()
        .disabled(!isAvailable)
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
                .font(Typography.largeTitle).tracking(Typography.largeTitleTracking)
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
            .pointerCursor()

            VStack(alignment: .leading, spacing: 8) {
                KickerLabel(section.kicker)
                Text(section.title)
                    .font(Typography.largeTitle).tracking(Typography.largeTitleTracking)
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
            // Defensive: the sidebar row is disabled on stable, so this branch is
            // unreachable there — but a stale `requestedSettingsSection` must not
            // be able to render an unreleased panel.
            if selection.isAvailable {
                NotesSettingsView(state: state)
            } else {
                ComingSoonPanel(section: .notes)
            }
        case .connectors:
            if selection.isAvailable {
                ConnectorsSettingsView(viewModel: viewModel, state: state)
            } else {
                ComingSoonPanel(section: .connectors)
            }
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
                        .fill(isRecording ? Theme.accentOn.opacity(0.25) : Theme.accentFill)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accentOn)
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
                        .foregroundStyle(isRecording ? Theme.accentOn : Theme.textPrimary)
                    Text(isRecording ? "Tap to stop" : "or tap to start")
                        .font(Typography.caption)
                        .foregroundStyle(isRecording ? Theme.accentOn.opacity(0.75) : Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(13)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isRecording ? Theme.accentFill : Theme.surfaceGlass)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(isRecording ? Theme.Ember.bright.opacity(0.55) : Theme.line, lineWidth: 1)
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
        .pointerCursor()
    }

    private func toggle() {
        if isRecording { viewModel.stopRecording() } else { viewModel.startRecording() }
    }
}

// MARK: - Sidebar account row

/// The signed-in identity at the bottom of the sidebar, with the account button
/// sitting to the right of the name and avatar — it opens `AccountPopover`
/// (email, account id, sign out) so there's no separate Account page.
/// Snapshot-guarded so the headless renderer (no Clerk environment) shows a
/// stable stand-in.
private struct SidebarAccountRow: View {
    let isSnapshot: Bool
    var signOut: () -> Void = {}

    @State private var showAccount = false

    var body: some View {
        row
            // Anchored above the row (it lives at the sidebar's bottom edge).
            .popover(isPresented: $showAccount, arrowEdge: .top) {
                AccountPopover(signOut: signOut)
            }
    }

    @ViewBuilder
    private var row: some View {
        if isSnapshot {
            AccountRowContent(
                name: "Alex Rivera",
                subtitle: "on-device",
                imageURL: nil,
                isOpen: showAccount,
                open: { showAccount = true }
            )
        } else {
            LiveSidebarAccountRow(isOpen: showAccount, open: { showAccount = true })
        }
    }
}

private struct LiveSidebarAccountRow: View {
    let isOpen: Bool
    var open: () -> Void
    @Environment(Clerk.self) private var clerk

    var body: some View {
        // No user means no session — say so, because the popup this row opens does.
        // `AccountIdentity.displayName(for: nil)` answers "Signed in" (its fallback
        // for a *signed-in* account with no name on it), so passing a nil user
        // straight through made the row assert the opposite of the popup.
        if let user = clerk.user {
            AccountRowContent(
                name: AccountIdentity.displayName(for: user),
                subtitle: "on-device",
                imageURL: AccountIdentity.imageURL(for: user),
                isOpen: isOpen,
                open: open
            )
        } else {
            AccountRowContent(
                name: "Not signed in",
                subtitle: "Sign in to dictate",
                imageURL: nil,
                isOpen: isOpen,
                open: open
            )
        }
    }
}

private struct AccountRowContent: View {
    let name: String
    let subtitle: String
    var imageURL: URL?
    var isOpen: Bool
    var open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
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

                // The account button, to the right of the name + avatar.
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isOpen ? Theme.accentText : Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background {
                        Circle().fill(hovering || isOpen ? Theme.surfaceGlass2 : Color.clear)
                    }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous)
                    .fill(hovering || isOpen ? Theme.surfaceGlass : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Account: \(name)")
        .accessibilityHint("Shows your email, account ID, and sign out")
        .pointerCursor()
    }

    private var initials: some View {
        ZStack {
            Circle().fill(Theme.accent2Fill)
            Text(initialsText)
                .font(Typography.sans(12, .bold))
                .foregroundStyle(Theme.accent2On)
        }
    }

    private var initialsText: String {
        let parts = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }
        let joined = parts.joined().uppercased()
        return joined.isEmpty ? "?" : joined
    }
}
