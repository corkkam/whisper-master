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
    case agents
    case traces
    case permissions
    case mesh
    case lab
    case about

    var id: String { rawValue }

    /// The four items shown in the sidebar.
    static let primary: [SettingsSection] = [.today, .notes, .connectors, .settings]
    /// The pages folded into the Settings screen's "More" list.
    static let secondary: [SettingsSection] = [.insights, .engine, .agents, .traces, .permissions, .mesh, .lab, .about]

    var isPrimary: Bool { SettingsSection.primary.contains(self) }

    /// Whether this section can be opened, given whether the Connectors/Notes
    /// feature set has shipped. Pure, so the gate is unit-testable for both
    /// channels without a bundle.
    func isAvailable(connectorsAndNotes: Bool) -> Bool {
        switch self {
        case .notes, .connectors: return connectorsAndNotes
        // Nearby Macs is on hold: peer discovery, the proximity beacons and the
        // remote-transcription listener all work, but none of it is finished
        // enough to hand to a user, so the page reads "Coming soon" on every
        // channel rather than shipping a half-built network surface. Nothing is
        // deleted — flip this back to `true` to bring the panel out again.
        case .mesh: return false
        // The Model Lab is a dev-build bench, not an unreleased product surface:
        // it is *absent* rather than "coming soon", because promising a stable
        // user a page that downloads 2 GB models would be promising the wrong
        // thing (see `FeatureFlags.modelLabAvailable`).
        case .lab: return FeatureFlags.modelLabAvailable
        default: return true
        }
    }

    /// Whether this section can be opened in *this* build.
    ///
    /// Connectors and Notes & Reminders are not yet released on stable (see
    /// `FeatureFlags`), and Nearby Macs is not released anywhere — they stay
    /// listed but read "Coming soon" and don't respond. Everything else is
    /// always available.
    var isAvailable: Bool {
        isAvailable(connectorsAndNotes: FeatureFlags.connectorsAndNotesAvailable)
    }

    /// Whether this page appears in the Settings "More" list at all.
    ///
    /// An unreleased *product* page stays listed and reads "Soon": the roadmap is
    /// deliberately visible, and dropping the row would make the feature look
    /// cancelled rather than pending. The Model Lab is not a roadmap entry — it
    /// is a bench for whoever is building the app — so on any other channel it is
    /// simply absent rather than promised.
    var isListed: Bool {
        self != .lab || FeatureFlags.modelLabAvailable
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
        case .agents: return "Coding agents"
        case .traces: return "Traces"
        case .permissions: return "Permissions"
        case .mesh: return "Nearby Macs"
        case .lab: return "Model Lab"
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
        case .agents: return "Dictate straight to a Claude Code session on this Mac."
        case .traces: return "What actually happened to the last few things you said."
        case .permissions: return "Whisper Master only asks for what it needs to work."
        case .mesh: return "Other Macs running Whisper Master on this Wi-Fi."
        case .lab: return "Bench open-source models against the real suites, on this Mac."
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
        case .agents: return "On this Mac"
        case .traces: return "Activity"
        case .permissions: return "Privacy"
        case .mesh: return "Mesh"
        case .lab: return "Dev build"
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
        case .agents: return "terminal"
        case .traces: return "list.bullet.indent"
        case .permissions: return "lock.shield"
        case .mesh: return "laptopcomputer"
        case .lab: return "flask"
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
    /// Which half of Notes & Reminders is showing. Held here, above both the sidebar
    /// sub-rows and the page's tab bar, so the two are one selection.
    @State private var notesTab: NotesTab = .overview
    /// Whether the sidebar's Notes group is expanded. Starts open — a collapsed
    /// group on first run hides the feature's two halves behind a chevron nobody
    /// knows to click.
    @State private var notesExpanded = true
    @State private var hasAutoFocusedSetup = false
    @State private var micGranted = false
    @State private var micDenied = false
    @State private var accessibilityGranted = false
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    // Notes & Reminders is the one primary that holds two distinct
                    // things, so it's the one that expands. The sub-rows select the
                    // same `notesTab` the page's own tab bar drives, so the sidebar
                    // and the content can never disagree about which half is up.
                    if section == .notes, section.isAvailable, notesExpanded {
                        ForEach(NotesTab.allCases) { candidate in
                            notesSubRow(candidate)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                // Only present when Sparkle has actually found something, so the
                // sidebar says nothing at all on a current build.
                if let version = state.availableUpdateVersion {
                    SidebarUpdateCard(version: version, install: checkForUpdates)
                }
                SidebarMicCard(state: state, viewModel: viewModel)
                SidebarAccountRow(
                    isSnapshot: isSnapshot,
                    updateVersion: state.availableUpdateVersion,
                    signOut: signOut,
                    checkForUpdates: checkForUpdates
                )
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
            // Tapping the Notes group both opens the page and expands the group.
            // Re-tapping it while already there collapses — a group header that can
            // only ever open is a one-way door.
            if section == .notes {
                notesExpanded = selection == .notes ? !notesExpanded : true
            }
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
                    RowTag("Soon")
                } else if section == .notes {
                    // A chevron rather than a second button: the row's own tap goes
                    // to the page, and this rotates to say the group underneath it
                    // is open. It's inside the row's label, so it can't steal the
                    // row's hit area — the tap below toggles the group *and*
                    // navigates, which is what a group header should do.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(notesExpanded ? 90 : 0))
                        .animation(
                            Theme.Motion.respecting(reduceMotion, Theme.Motion.quick),
                            value: notesExpanded)
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

    /// A child row under the Notes group: Overview / Notes / Reminders.
    ///
    /// Visually subordinate on purpose — indented, smaller type, and a *rule* down
    /// the left rather than the parent's pill-and-glow. Giving a child the same
    /// selected treatment as a top-level item would make the sidebar read as seven
    /// peers instead of four sections, one of which is open.
    private func notesSubRow(_ candidate: NotesTab) -> some View {
        let isSelected = selection == .notes && notesTab == candidate
        return Button {
            notesTab = candidate
            selection = .notes
        } label: {
            HStack(spacing: 9) {
                // The indent rule, lit for the selected child.
                Rectangle()
                    .fill(isSelected ? Theme.accent : Theme.line)
                    .frame(width: 2, height: 16)
                Image(systemName: candidate.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.textTertiary)
                    .frame(width: 14, alignment: .center)
                Text(candidate.title)
                    .font(Typography.sans(13, isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.leading, 22)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous)
                        .fill(Theme.accentSoft.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Notes and reminders: \(candidate.title)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// How wide the content column is allowed to get.
    ///
    /// 780 is a reading measure — right for pages that are prose and settings rows,
    /// and wrong for the notes canvas, which is a *grid of cards beside a reminders
    /// column*. At 780 that bifurcation collapses to one sticky per row with the
    /// reminders squeezed beside it, so the notes page gets a wider measure. The
    /// window is 80% of the screen (`applyDefaultWindowFrame`), so the room exists.
    /// The lab joins notes at the wider measure for the same reason: it is a
    /// table of models beside a rail of cases, not a reading column.
    private var contentMaxWidth: CGFloat {
        selection == .notes || selection == .lab ? 1180 : 780
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
                NotesSettingsView(state: state, tab: $notesTab)
            } else {
                ComingSoonPanel(section: .notes)
            }
        case .connectors:
            if selection.isAvailable {
                ConnectorsSettingsView(state: state)
            } else {
                ComingSoonPanel(section: .connectors)
            }
        case .settings:
            GeneralSettingsView(viewModel: viewModel, state: state, openSubPage: { selection = $0 })
        case .engine:
            EngineSettingsView(viewModel: viewModel, state: state)
        case .agents:
            AgentSettingsView(state: state)
        case .mesh:
            if selection.isAvailable {
                MeshSettingsView(viewModel: viewModel, state: state)
            } else {
                ComingSoonPanel(section: .mesh)
            }
        case .lab:
            if selection.isAvailable {
                LabSettingsView(state: state)
            } else {
                ComingSoonPanel(section: .lab)
            }
        case .traces:
            TracesSettingsView(viewModel: viewModel, state: state)
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

// MARK: - Sidebar update card

/// "There is a new version" in the sidebar, and the one click that installs it.
///
/// It is drawn only while `AppState.availableUpdateVersion` is set, which the
/// AppDelegate's Sparkle delegate writes from a **silent** check
/// (`checkForUpdateInformation()`), so a waiting update announces itself in the
/// window without a Sparkle panel appearing over whatever the user was doing.
/// The tap runs the ordinary `checkForUpdates` action — Sparkle then shows its
/// own release notes and Install button, which is the surface that owns the
/// download, the signature check and the relaunch.
///
/// Accent-tinted rather than a plain glass card: it is news, and it sits beside
/// the mic card, which must stay the loudest thing at the foot of the sidebar —
/// hence the smaller glyph and the two tight lines.
private struct SidebarUpdateCard: View {
    let version: String
    var install: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: install) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Theme.accentFill)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.accentOn)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Update ready")
                        .font(Typography.heading(13, relativeTo: .callout))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Version \(version)")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accentText)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.accentSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                Theme.accent.opacity(hovering ? 0.42 : 0.22), lineWidth: 1)
                    )
                    .shadow(color: Theme.Ember.base.opacity(0.18), radius: 10, x: 0, y: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Update ready, version \(version)")
        .accessibilityHint("Installs the update")
        .pointerCursor()
    }
}

// MARK: - Sidebar mic card

/// The sidebar's push-to-talk affordance: idle names the bound key, recording
/// shows a pulsing "Listening…" state. Tapping toggles recording (the global
/// hotkey remains the primary trigger).
private struct SidebarMicCard: View {
    @Bindable var state: AppState
    let viewModel: DictationViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var isRecording: Bool { state.phase == .recording }

    /// Names the key that is actually bound, not a hardcoded one — the picker in
    /// Recording settings can point this anywhere, and a card claiming ⌥ while the
    /// bound key is 🌐 teaches the wrong gesture. Toggle mode says "Tap", since
    /// holding is not what starts a recording there.
    private var idleTitle: String {
        let verb = state.holdToTalkEnabled ? "Hold" : "Tap"
        return "\(verb) \(state.hotkey.capName) to dictate"
    }

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
                    Text(isRecording ? "Listening…" : idleTitle)
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
    var updateVersion: String?
    var signOut: () -> Void = {}
    var checkForUpdates: () -> Void = {}

    @State private var showAccount = false

    var body: some View {
        row
            // Anchored above the row (it lives at the sidebar's bottom edge).
            .popover(isPresented: $showAccount, arrowEdge: .top) {
                AccountPopover(
                    updateVersion: updateVersion,
                    signOut: signOut,
                    checkForUpdates: {
                        // Sparkle's window is app-modal-ish and this popover sits
                        // above it, so close ours before handing over.
                        showAccount = false
                        checkForUpdates()
                    }
                )
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
