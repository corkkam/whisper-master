import SwiftUI

/// The "Connectors" tab: the user's **named connections**, many per kind.
///
/// This replaced a grid of one-tile-per-kind toggles, which couldn't express two of
/// anything and left eight tiles permanently on "Needs setup" because nothing behind
/// them was implemented. The page now shows only connections that exist and can
/// actually be read, and everything else lives behind "Add connector", where a kind
/// without an implementation is honestly marked rather than offering a dead button.
///
/// Three things about the *layout* are deliberate, and each fixes a way the first
/// pass of this page was hard to use:
///
/// - **Connections come first.** The teaching copy that used to open the page was a
///   five-line card above the only content anyone came here for. It's now a single
///   line with the chord as a keycap, and the prose is one click away — the same
///   trade `NotesSettingsView.assistantHint` makes, for the same reason: the keycap
///   is the part that teaches, the paragraph is the part nobody re-reads.
/// - **A row's actions are visible.** Every action (rename, re-pick calendars, test,
///   reconnect, remove) used to live behind a 26pt `⋯` with no hover affordance, so
///   the page looked like it could only toggle things on and off. They're now in a
///   drawer the row itself opens, which also means they *render* — `ImageRenderer`
///   can't draw an AppKit `Menu`, so the snapshot path needed a fake glyph before.
/// - **A row says what it reads.** "Reading 2 calendars" never named the two. The
///   drawer does, which is the only way to check a connector is bound to what you
///   think it is without walking through the re-pick sheet.
struct ConnectorsSettingsView: View {
    // No `viewModel`: the only thing on this page that needed one was the
    // assistant/speech block, which moved to Settings. The page is now purely a
    // view over `state.connectorStore`.
    @Bindable var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var store: ConnectorInstanceStore { state.connectorStore }

    /// Today's real events, merged across the enabled calendar instances.
    @State private var todayEvents: [DayEvent] = []
    @State private var isAddingConnector = false
    @State private var renaming: ConnectorInstance?
    @State private var editingCalendars: ConnectorInstance?
    @State private var reconnecting: ConnectorInstance?
    /// The instance whose browser re-sign-in is in flight, so its repair buttons
    /// read "Waiting for your browser…" and a second flow can't start under it.
    @State private var reSigningIn: UUID?
    /// The connection currently being checked, and the last result per connection —
    /// so "Test connection" reports something rather than appearing to do nothing.
    @State private var testing: UUID?
    @State private var testResults: [UUID: String] = [:]
    /// The one row whose drawer is open. One at a time: two open drawers push the
    /// rest of the page off screen and neither is easier to read for it.
    @State private var openRow: UUID?
    /// Calendar titles for an expanded row, resolved from EventKit when the drawer
    /// opens rather than on every render — `availableCalendars` walks the store.
    @State private var calendarTitles: [UUID: String] = [:]
    @State private var showsAskHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            askBar
            connectedSection
            if showTodaySection { todaySection }
            // What's left of the old agent block. The assistant switch and the
            // spoken-answer preferences moved to Settings — they're preferences, and
            // this page is about accounts; a grant list isn't, so it stays.
            ConnectorPermissionsSection(state: state)
        }
        .onAppear {
            refreshCalendarAccess()
            refreshToday()
        }
        .sheet(isPresented: $isAddingConnector) {
            AddConnectorSheet(store: store) { refreshToday() }
        }
        .sheet(item: $renaming) { instance in
            RenameConnectorSheet(instance: instance, store: store)
        }
        .sheet(item: $editingCalendars) { instance in
            CalendarSelectionSheet(instance: instance, store: store) {
                calendarTitles[instance.id] = nil
                refreshToday()
            }
        }
        .sheet(item: $reconnecting) { instance in
            ReconnectConnectorSheet(instance: instance, store: store) {
                testResults[instance.id] = "Reconnected."
                refreshToday()
            }
        }
    }

    // MARK: - Ask about your day

    /// One line, with the chord as a keycap and the rest folded away.
    ///
    /// The chord is the *only* way to reach any of this, so it can't be dropped —
    /// but it doesn't earn a five-line card above the connections either. The keycap
    /// stays visible forever; the detail expands in place for whoever wants it.
    private var askBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.quick)) {
                    showsAskHelp.toggle()
                }
            } label: {
                HStack(spacing: 11) {
                    // No leading glyph: `compactName` already opens with the Globe
                    // character for fn, so an `Image(systemName: "globe")` in front of
                    // it draws the same key twice.
                    Text(ModifierChord.command.compactName)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule(style: .continuous).fill(Theme.surface))
                        .overlay(Capsule(style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                    Text("Hold and ask \u{201C}what's my day?\u{201D} \u{2014} the answer lands in the notch")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(showsAskHelp ? "Less" : "How it works")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.accentText)
                        .fixedSize()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accentText)
                        .rotationEffect(.degrees(showsAskHelp ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel(
                "Talk to the assistant with \(ModifierChord.command.displayName). \(showsAskHelp ? "Hide" : "Show") details.")

            if showsAskHelp {
                VStack(alignment: .leading, spacing: 8) {
                    RowDivider()
                    Text("Name a connector out loud \u{2014} \u{201C}what's on my work calendar\u{201D} \u{2014} to narrow it; ask plainly and every calendar is merged.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                    Text("The same chord files notes and reminders, and runs anything your connectors can do. It's the one way in to the assistant \u{2014} holding your push-to-talk key on its own always just dictates.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassTile(radius: 14)
    }

    // MARK: - Connected instances

    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionLabel("Your connections")
                if !store.instances.isEmpty {
                    Chip("\(store.instances.count)")
                }
                Spacer()
                if !store.instances.isEmpty {
                    SecondaryButton(title: "Add connector", icon: "plus") { isAddingConnector = true }
                        .disabled(isSnapshot)
                }
            }

            if calendarNeedsAccess { calendarAccessCard }

            if store.instances.isEmpty {
                emptyState
            } else {
                SettingsCard {
                    ForEach(Array(store.ordered.enumerated()), id: \.element.id) { index, instance in
                        if index > 0 { RowDivider() }
                        instanceRow(instance)
                    }
                }
            }
        }
    }

    /// An empty page's one job is to get the first connection made, so the call to
    /// action is a real button here rather than the secondary one in the header —
    /// which is hidden while the list is empty so there's only ever one of them.
    private var emptyState: some View {
        SettingsCard {
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.Accent.n300.opacity(0.5))
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.Accent.n800)
                }
                .frame(width: 48, height: 48)

                VStack(spacing: 5) {
                    Text("No connectors yet")
                        .font(Typography.headline).tracking(Typography.headlineTracking)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Add a calendar and name it \u{2014} \u{201C}Work\u{201D}, \u{201C}Personal\u{201D} \u{2014} then ask about your day and the answer says which one it came from.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 400)
                }

                PrimaryButton(title: "Add your first connector", icon: "plus") {
                    isAddingConnector = true
                }
                .disabled(isSnapshot)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
        }
    }

    /// One connection: icon, the **user's name for it**, the account identity under
    /// it, a state pill, a switch, and a drawer holding everything else.
    private func instanceRow(_ instance: ConnectorInstance) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                // The whole identity block opens the drawer, so the target is a row
                // rather than a 30pt glyph — but it stops short of the switch, which
                // has its own meaning and must not be a click away from a surprise.
                Button {
                    toggleDrawer(instance)
                } label: {
                    HStack(spacing: 13) {
                        tile(instance)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(instance.displayLabel)
                                    .font(Typography.headline).tracking(Typography.headlineTracking)
                                    .foregroundStyle(Theme.textPrimary)
                                if store.isDefault(instance.id), store.instances(of: instance.kind).count > 1 {
                                    Chip("Default")
                                }
                            }
                            // The identity stays visible even after a rename, so "Work"
                            // is still traceable to the account it reads.
                            Text(subtitle(instance))
                                .font(Typography.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel("\(instance.displayLabel), \(statusText(instance)). \(openRow == instance.id ? "Hide" : "Show") details.")

                StatusPill(text: statusText(instance), tone: statusTone(instance))

                // After the pill, not before it: the pill's width changes with its
                // words, and a pin ahead of it wandered from row to row.
                notchPinButton(instance)

                ThemeToggle(
                    isOn: Binding(
                        get: { instance.isEnabled },
                        set: { store.setEnabled(instance.id, $0); refreshToday() }),
                    label: instance.displayLabel)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(openRow == instance.id ? 180 : 0))
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 14)

            // A failure needs a sentence and a repair button, which is more than a
            // pill can hold — so it gets its own strip, always visible, never behind
            // the drawer. An instance never silently reads nothing.
            if let error = instance.lastError { errorStrip(instance, error) }

            if openRow == instance.id { drawer(instance) }
        }
    }

    /// Pins the connection to the notch band, where it becomes a tab with its own
    /// count. The same pin glyph a note uses for the same act. At the cap the
    /// control stays drawn but inert, with the reason in its tooltip — a pin that
    /// vanished at three would read as a feature that only some rows have.
    private func notchPinButton(_ instance: ConnectorInstance) -> some View {
        let pinned = store.isPinnedToNotch(instance.id)
        let atCap = !pinned && !store.canPinToNotch
        let tooltip = pinned
            ? "Unpin from the notch"
            : atCap
                ? "The notch holds \(ConnectorInstanceStore.notchPinLimit) connectors. Unpin one first."
                : "Pin to the notch"
        return Button {
            store.setPinnedToNotch(instance.id, !pinned)
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(pinned ? Theme.accent : Theme.textTertiary)
        }
        .iconButton(size: 28, tooltip: tooltip)
        .disabled(atCap || isSnapshot)
        .accessibilityLabel(pinned
            ? "Unpin \(instance.displayLabel) from the notch"
            : "Pin \(instance.displayLabel) to the notch")
    }

    private func tile(_ instance: ConnectorInstance) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tileTint(instance))
            Image(systemName: instance.kind.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tileGlyph(instance))
        }
        .frame(width: 38, height: 38)
    }

    /// "iCal · Other, Subscribed Calendars" under a row already titled "iCal" spent a
    /// line saying the word twice — so the kind is dropped whenever the user's name
    /// for the connection already is it.
    private func subtitle(_ instance: ConnectorInstance) -> String {
        let identity = instance.identity.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = instance.kind.displayName
        if identity.isEmpty { return kind }
        if instance.displayLabel.caseInsensitiveCompare(kind) == .orderedSame { return identity }
        return "\(kind) \u{00B7} \(identity)"
    }

    // MARK: Row state

    private func statusText(_ instance: ConnectorInstance) -> String {
        if testing == instance.id { return "Checking\u{2026}" }
        if instance.lastError != nil { return "Needs attention" }
        if !instance.isEnabled { return "Paused" }
        guard let identifiers = instance.config.calendarIdentifiers else { return "Connected" }
        if identifiers.isEmpty { return "All calendars" }
        return "\(identifiers.count) calendar\(identifiers.count == 1 ? "" : "s")"
    }

    private func statusTone(_ instance: ConnectorInstance) -> StatusPill.Tone {
        if testing == instance.id { return .neutral }
        if instance.lastError != nil { return .danger }
        return instance.isEnabled ? .positive : .neutral
    }

    private func errorStrip(_ instance: ConnectorInstance, _ error: ConnectorError) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.danger)
            Text(error.message)
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 10)
            if let repair = repairButtonTitle(instance, error) {
                Button(repair) { repairAction(instance, error) }
                    .textButton()
                    .disabled(isSnapshot || reSigningIn != nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.dangerSoft))
        .padding(.bottom, 14)
    }

    // MARK: Row drawer

    /// What this connection is bound to, and everything you can do to it.
    ///
    /// These were all `Menu` items before. A menu is fine for a power user who knows
    /// it's there; it is invisible to everyone else, and it left the row looking like
    /// a switch with a decoration beside it.
    private func drawer(_ instance: ConnectorInstance) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            RowDivider()

            VStack(alignment: .leading, spacing: 7) {
                detail("Reads", reads(instance))
                if !instance.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    detail("Account", instance.identity)
                }
                detail("Added", Self.dayFormatter.string(from: instance.connectedAt))
            }

            HStack(spacing: 4) {
                Button("Test connection") { testConnection(instance) }
                    .textButton()
                    .disabled(isSnapshot || testing != nil)
                if instance.descriptor.isSystemBacked {
                    Button("Choose calendars\u{2026}") { editingCalendars = instance }
                        .textButton()
                        .disabled(isSnapshot)
                }
                // A credential-bearing connection can have its secret replaced in
                // place, and a managed Google grant re-signed in place. Without this
                // the only fix for a rotated token was Remove + add again.
                switch Self.repairRoute(for: instance,
                                        oauthConfigured: GoogleOAuthConfig.isConfigured) {
                case .signInAgain:
                    Button(reSigningIn == instance.id
                           ? "Waiting for your browser\u{2026}"
                           : "Sign in again\u{2026}") { reSignIn(instance) }
                        .textButton()
                        .disabled(isSnapshot || reSigningIn != nil)
                case .replaceSecret:
                    Button("Reconnect\u{2026}") { reconnecting = instance }
                        .textButton()
                        .disabled(isSnapshot)
                case .addSheet:
                    EmptyView()
                }
                Button("Rename\u{2026}") { renaming = instance }
                    .textButton()
                    .disabled(isSnapshot)
                if store.instances(of: instance.kind).count > 1, !store.isDefault(instance.id) {
                    Button("Make default") { store.setDefault(instance.id) }
                        .textButton()
                        .disabled(isSnapshot)
                }
                Spacer(minLength: 10)
                DestructiveButton(title: "Remove", icon: "trash") {
                    if openRow == instance.id { openRow = nil }
                    store.remove(instance.id)
                    refreshToday()
                }
                .disabled(isSnapshot)
            }

            // The result of an explicit check belongs next to the button that ran it,
            // which is the whole reason the check exists: the row could only ever
            // report the failure of whatever last happened to read through it, so a
            // connection never used since it was added looked healthy.
            if testing == instance.id {
                checkLine("Checking with the provider\u{2026}", tone: .neutral)
            } else if let result = testResults[instance.id] {
                checkLine(result, tone: instance.lastError == nil ? .positive : .danger)
            }
        }
        .padding(.bottom, 16)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func checkLine(_ text: String, tone: StatusPill.Tone) -> some View {
        HStack(spacing: 7) {
            StatusDot(color: tone.dot, size: 6)
            Text(text)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The calendars by **name**, which is the answer to "is this bound to what I
    /// think it is" — a count never was.
    private func reads(_ instance: ConnectorInstance) -> String {
        guard let identifiers = instance.config.calendarIdentifiers else {
            return capabilityWords(instance)
        }
        if identifiers.isEmpty { return "Every calendar on this Mac" }
        if let titles = calendarTitles[instance.id] { return titles }
        return "\(identifiers.count) calendar\(identifiers.count == 1 ? "" : "s")"
    }

    /// What a non-calendar connection is good for, in the user's words. Read off the
    /// descriptor's capabilities rather than hard-coded per kind, so a new catalog
    /// entry needs no change here.
    private func capabilityWords(_ instance: ConnectorInstance) -> String {
        let words = ConnectorCapability.allCases
            .filter { instance.provides($0) }
            .map { capability -> String in
                switch capability {
                case .events: return "Calendar events"
                case .mail: return "Mail"
                case .messages: return "Messages"
                case .tasks: return "Tasks"
                case .files: return "Files"
                }
            }
        return words.isEmpty ? "Nothing yet" : words.joined(separator: " \u{00B7} ")
    }

    private func toggleDrawer(_ instance: ConnectorInstance) {
        withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.quick)) {
            openRow = openRow == instance.id ? nil : instance.id
        }
        guard openRow == instance.id else { return }
        loadCalendarTitles(instance)
    }

    /// Resolved once per open rather than per render: `availableCalendars` walks
    /// EventKit's store, and there's no reason to do that on every layout pass.
    private func loadCalendarTitles(_ instance: ConnectorInstance) {
        guard !isSnapshot,
              calendarTitles[instance.id] == nil,
              let identifiers = instance.config.calendarIdentifiers,
              !identifiers.isEmpty else { return }
        let wanted = Set(identifiers)
        let titles = CalendarConnector.shared.availableCalendars(for: instance.kind)
            .filter { wanted.contains($0.identifier) }
            .map(\.title)
        guard !titles.isEmpty else { return }
        calendarTitles[instance.id] = titles.joined(separator: ", ")
    }

    private func repairAction(_ instance: ConnectorInstance, _ error: ConnectorError) {
        switch error {
        case .needsCalendarAccess:
            Task { @MainActor in
                let granted = await CalendarConnector.shared.requestAccess()
                store.calendarAccessGranted = granted
                if granted {
                    for kind in ConnectorKind.allCases {
                        store.clearErrors(ofKind: kind, matching: .needsCalendarAccess)
                    }
                }
                refreshToday()
            }
        case .calendarMissing:
            editingCalendars = instance
        case .credentialInvalid, .tokenExpired:
            // Repair *this* connection rather than opening the add sheet, which built
            // a second one and left the broken original in the list beside it.
            switch Self.repairRoute(for: instance, oauthConfigured: GoogleOAuthConfig.isConfigured) {
            case .signInAgain: reSignIn(instance)
            case .replaceSecret: reconnecting = instance
            case .addSheet: isAddingConnector = true
            }
        case .rateLimited, .unreachable:
            break
        }
    }

    /// The failure strip's repair title. A managed Google grant is healed by
    /// signing in again, and the button must say so — "Reconnect" reads as the
    /// paste sheet it would not open.
    private func repairButtonTitle(_ instance: ConnectorInstance,
                                   _ error: ConnectorError) -> String? {
        guard let base = error.repairTitle else { return nil }
        switch error {
        case .credentialInvalid, .tokenExpired:
            guard case .signInAgain = Self.repairRoute(
                for: instance, oauthConfigured: GoogleOAuthConfig.isConfigured)
            else { return base }
            return reSigningIn == instance.id ? "Waiting for your browser\u{2026}" : "Sign in again"
        default:
            return base
        }
    }

    /// Where the repair for an auth failure leads. A managed Google grant has no
    /// secret to paste, so its only honest repair is the same browser sign-in that
    /// made it, run over the same instance — the old fields-based rule sent an
    /// expired Google Calendar to the Add sheet (where the same account is refused
    /// as a duplicate, so the only exit was Remove + re-add, losing the label and
    /// every standing grant) and a signed-in Gmail to the paste sheet (whose saved
    /// plain token the config then treated as a refreshable grant, dying an hour
    /// later). Pure, so `ConnectorRepairRouteTests` pins the routing.
    enum RepairRoute: Equatable {
        /// Managed Google grant: re-run the browser sign-in over this instance.
        case signInAgain
        /// Pasted credential: replace the secret in place (`ReconnectConnectorSheet`).
        case replaceSecret
        /// Nothing better to offer: the catalog sheet.
        case addSheet
    }

    static func repairRoute(for instance: ConnectorInstance,
                            oauthConfigured: Bool) -> RepairRoute {
        if instance.config.isManagedGoogleGrant {
            // Without a client id in the build there is no browser flow to re-run.
            return oauthConfigured && Self.reSignInScopes(for: instance.kind) != nil
                ? .signInAgain : .addSheet
        }
        return !instance.descriptor.isSystemBacked
            && !instance.descriptor.fields.isEmpty
            && ProviderRegistry.hasProvider(for: instance.kind)
            ? .replaceSecret : .addSheet
    }

    /// The scopes a repair re-requests — the same set the original connect asked
    /// for, so the healed grant can do everything the old one could.
    nonisolated static func reSignInScopes(for kind: ConnectorKind) -> [String]? {
        switch kind {
        case .googleCalendar: return GoogleOAuthConfig.Scope.calendarConnect
        case .gmail: return GoogleOAuthConfig.Scope.gmailConnect
        default: return nil
        }
    }

    /// Case-insensitive, because Google reports the address in the account's own
    /// casing while the stored identity may differ.
    nonisolated static func identityMatches(_ new: String, existing: String) -> Bool {
        new.compare(existing, options: .caseInsensitive) == .orderedSame
    }

    /// Heal an expired managed Google grant by running the same browser sign-in
    /// that created it, saving over the same instance id — label, default flag,
    /// and standing grants all survive because nothing is removed or re-added.
    /// The account is pinned: a sign-in that comes back as a different mailbox is
    /// refused, because this connector's permission grants name *this* account
    /// and must not silently rebind to another one (`login_hint` only prefills;
    /// the browser can still switch).
    private func reSignIn(_ instance: ConnectorInstance) {
        guard let scopes = Self.reSignInScopes(for: instance.kind) else { return }
        reSigningIn = instance.id
        testResults[instance.id] = nil
        Task { @MainActor in
            defer { reSigningIn = nil }
            do {
                let tokens = try await OAuthPKCEFlow().authorize(
                    scopes: scopes, account: .reuse(email: instance.identity))
                // Merged over the stored credential, so a response that omits the
                // refresh token keeps the old one — same as every refresh path.
                let credential = tokens.merged(
                    into: ConnectorCredentials.load(for: instance.id) ?? ConnectorCredential())
                guard let provider = ProviderRegistry.provider(for: instance) else {
                    testResults[instance.id] = "No implementation for this connector yet."
                    return
                }
                let result = await provider.validate(credential, config: instance.config)
                guard result.isValid else {
                    testResults[instance.id] = result.failure ?? "Google rejected the sign-in."
                    return
                }
                guard Self.identityMatches(result.identity, existing: instance.identity) else {
                    testResults[instance.id] = "That signed in as \(result.identity), but this "
                        + "connector is \(instance.identity). Use that account, or add a new "
                        + "connector for the other one."
                    return
                }
                _ = ConnectorCredentials.save(credential, for: instance.id)
                store.recordReconnection(instance.id,
                                         identity: result.identity,
                                         config: result.config)
                testResults[instance.id] = "Signed in just now \u{2014} working."
                refreshToday()
            } catch OAuthFlowError.userCancelled {
                // Backing out of the browser isn't an error; the row keeps its strip.
            } catch {
                testResults[instance.id] = "Sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    /// Check a saved connection against the real provider, now.
    private func testConnection(_ instance: ConnectorInstance) {
        guard let provider = ProviderRegistry.provider(for: instance) else {
            testResults[instance.id] = "No implementation for this connector yet."
            return
        }
        testing = instance.id
        testResults[instance.id] = nil
        Task { @MainActor in
            let credential = ConnectorCredentials.load(for: instance.id) ?? ConnectorCredential()
            let result = await provider.validate(credential, config: instance.config)
            testing = nil
            if result.isValid {
                // A successful check is also a repair: it proves the stored credential
                // works, so a stale failure must not keep the instance out of reads.
                store.recordReconnection(instance.id,
                                         identity: result.identity,
                                         config: result.config)
                testResults[instance.id] = "Checked just now \u{2014} working."
            } else {
                store.setError(instance.id, .credentialInvalid)
                testResults[instance.id] = result.failure ?? "That connection was rejected."
            }
            refreshToday()
        }
    }

    private func tileTint(_ instance: ConnectorInstance) -> Color {
        if instance.lastError != nil { return Theme.dangerSoft }
        if !instance.isEnabled { return Theme.Neutral.n300.opacity(0.6) }
        return instance.descriptor.isSystemBacked
            ? Theme.Accent.n300.opacity(0.7)
            : Theme.Sage.n300.opacity(0.7)
    }

    private func tileGlyph(_ instance: ConnectorInstance) -> Color {
        if instance.lastError != nil { return Theme.danger }
        if !instance.isEnabled { return Theme.Neutral.n800 }
        return instance.descriptor.isSystemBacked ? Theme.Accent.n800 : Theme.Sage.n800
    }

    // MARK: - Today (live, merged across instances)

    private var showTodaySection: Bool {
        isSnapshot || (store.hasReadableCalendar && store.calendarAccessGranted)
    }

    private var displayEvents: [DayEvent] {
        isSnapshot ? Self.mockEvents : todayEvents
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Today")
                Spacer()
                Text(store.readable(providing: .events).count > 1 || isSnapshot
                     ? "Merged from your calendars"
                     : "Live from your calendar")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            let events = displayEvents
            if events.isEmpty {
                SettingsCard {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Theme.success)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Nothing on your calendar today")
                                .font(Typography.headline).tracking(Typography.headlineTracking)
                                .foregroundStyle(Theme.textPrimary)
                            Text("You're clear. Ask \u{201C}what's my day\u{201D} anytime.")
                                .font(Typography.subheadline).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 14)
                }
            } else {
                SettingsCard {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { RowDivider() }
                        eventRow(event)
                    }
                }
            }
        }
    }

    private func eventRow(_ event: DayEvent) -> some View {
        HStack(spacing: 14) {
            Text(event.isAllDay ? "All day" : Self.timeFormatter.string(from: event.start))
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(event.isUpcoming ? Theme.accent : Theme.textTertiary)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(Typography.headline).tracking(Typography.headlineTracking)
                    .foregroundStyle(Theme.textPrimary)
                    .strikethrough(!event.isUpcoming)
                // Names the *connector* the event came from — the payoff for having
                // named them, and impossible in the old one-query-for-everything model.
                if !event.provenance.isEmpty {
                    Text(event.provenance)
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 12)
        }
        .padding(.vertical, 13)
    }

    private func refreshToday() {
        guard !isSnapshot else { return }
        refreshCalendarAccess()
        todayEvents = DaySummaryService.build(store: store).events
    }

    // MARK: - Calendar access

    /// Shown when a calendar connector exists but macOS calendar access isn't granted
    /// yet — the one thing standing between a connection and real data. It sits above
    /// the list rather than at the top of the page: it's about those connections, and
    /// a page with no connectors can never need it.
    private var calendarAccessCard: some View {
        SettingsCard {
            SettingsRow("Allow calendar access",
                        subtitle: "Your calendar stays on this Mac. It's only read to summarise your day.") {
                SecondaryButton(title: "Allow", icon: "calendar") {
                    Task {
                        let granted = await CalendarConnector.shared.requestAccess()
                        store.calendarAccessGranted = granted
                        if granted {
                            for kind in ConnectorKind.allCases {
                                store.clearErrors(ofKind: kind, matching: .needsCalendarAccess)
                            }
                        }
                        refreshToday()
                    }
                }
                .disabled(isSnapshot)
            }
        }
    }

    /// Never in a snapshot render: there's no TCC grant in the headless renderer, so
    /// reading the real authorization status would stomp the seeded "granted" state and
    /// the panel would render its setup prompt instead of the connections.
    private func refreshCalendarAccess() {
        guard !isSnapshot else { return }
        store.calendarAccessGranted = CalendarConnector.shared.isAuthorized
    }

    private var calendarNeedsAccess: Bool {
        !store.instances.filter { $0.descriptor.isSystemBacked }.isEmpty && !store.calendarAccessGranted
    }

    // MARK: - Statics

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// Believable events for the headless snapshot renderer (no calendar access
    /// there). Times are relative so they always look like "today", and the instance
    /// labels match the two seeded Google Calendar instances so the merged view reads
    /// the way it does on a real Mac.
    static var mockEvents: [DayEvent] {
        let now = Date()
        func at(_ hoursFromNow: Double, _ minutes: Double = 60) -> (Date, Date) {
            let start = now.addingTimeInterval(hoursFromNow * 3600)
            return (start, start.addingTimeInterval(minutes * 60))
        }
        let a = at(-1), b = at(0.5, 30), c = at(3)
        return [
            DayEvent(id: "m1", title: "Team stand-up", start: a.0, end: a.1, isAllDay: false,
                     calendarTitle: "Work", sourceTitle: "Google", instanceLabel: "Work"),
            DayEvent(id: "m2", title: "Design review — Daylight tokens", start: b.0, end: b.1, isAllDay: false,
                     calendarTitle: "Work", sourceTitle: "Google", instanceLabel: "Work"),
            DayEvent(id: "m3", title: "1:1 with Sam", start: c.0, end: c.1, isAllDay: false,
                     calendarTitle: "Personal", sourceTitle: "Google", instanceLabel: "Personal"),
        ]
    }
}

/// `sheet(item:)` needs an `Identifiable` binding; `ConnectorInstance` already is, so
/// this is only here to keep the call sites readable.
private extension View {
    func sheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } })) {
                if let value = item.wrappedValue { content(value) }
            }
    }
}
