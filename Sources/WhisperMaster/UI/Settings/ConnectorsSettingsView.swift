import SwiftUI

/// The "Connectors" tab: the user's **named connections**, many per kind.
///
/// This replaced a grid of one-tile-per-kind toggles, which couldn't express two of
/// anything and left eight tiles permanently on "Needs setup" because nothing behind
/// them was implemented. The page now shows only connections that exist and can
/// actually be read, and everything else lives behind "Add connector", where a kind
/// without an implementation is honestly marked rather than offering a dead button.
struct ConnectorsSettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot

    private var store: ConnectorInstanceStore { state.connectorStore }

    /// Today's real events, merged across the enabled calendar instances.
    @State private var todayEvents: [DayEvent] = []
    @State private var isAddingConnector = false
    @State private var renaming: ConnectorInstance?
    @State private var editingCalendars: ConnectorInstance?
    @State private var reconnecting: ConnectorInstance?
    /// The connection currently being checked, and the last result per connection —
    /// so "Test connection" reports something rather than appearing to do nothing.
    @State private var testing: UUID?
    @State private var testResults: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            askSection
            connectedSection
            if showTodaySection { todaySection }
            ConnectorAgentSettings(viewModel: viewModel, state: state)
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
            CalendarSelectionSheet(instance: instance, store: store) { refreshToday() }
        }
        .sheet(item: $reconnecting) { instance in
            ReconnectConnectorSheet(instance: instance, store: store) {
                testResults[instance.id] = "Reconnected."
                refreshToday()
            }
        }
    }

    // MARK: - Connected instances

    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Your connections")
                Spacer()
                SecondaryButton(title: "Add connector", icon: "plus") { isAddingConnector = true }
                    .disabled(isSnapshot)
            }

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

    private var emptyState: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("No connectors yet")
                    .font(Typography.headline).tracking(Typography.headlineTracking)
                    .foregroundStyle(Theme.textPrimary)
                Text("Add a calendar and name it — \u{201C}Work\u{201D}, \u{201C}Personal\u{201D} — then ask about your day and the answer says which one it came from.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
        }
    }

    /// One connection: icon, the **user's name for it**, the account identity under
    /// it, a default badge, an honest status line, and a ⋯ menu.
    private func instanceRow(_ instance: ConnectorInstance) -> some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tileTint(instance))
                Image(systemName: instance.kind.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tileGlyph(instance))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(instance.displayLabel)
                        .font(Typography.headline).tracking(Typography.headlineTracking)
                        .foregroundStyle(Theme.textPrimary)
                    if store.isDefault(instance.id), store.instances(of: instance.kind).count > 1 {
                        Chip("Default")
                    }
                }
                // The identity stays visible even after a rename, so "Work" is still
                // traceable to the account it reads.
                Text("\(instance.kind.displayName) · \(instance.identity)")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                statusLine(instance)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                ThemeToggle(
                    isOn: Binding(
                        get: { instance.isEnabled },
                        set: { store.setEnabled(instance.id, $0); refreshToday() }),
                    label: instance.displayLabel)
                menu(for: instance)
            }
        }
        .padding(.vertical, 12)
    }

    /// The one line that says what's actually true about this connection — including
    /// a repair action when it's broken. An instance never silently reads nothing.
    @ViewBuilder
    private func statusLine(_ instance: ConnectorInstance) -> some View {
        if testing == instance.id {
            HStack(spacing: 6) {
                StatusDot(color: Theme.Neutral.n300, size: 6)
                Text("Checking\u{2026}").font(Typography.caption).foregroundStyle(Theme.textTertiary)
            }
        } else if let result = testResults[instance.id], instance.lastError == nil {
            // The outcome of an explicit check outranks the passive scope line — the
            // user just asked a question and deserves the answer, not the same row
            // they were looking at before they asked.
            HStack(spacing: 6) {
                StatusDot(color: Theme.success, size: 6)
                Text(result).font(Typography.caption).foregroundStyle(Theme.textTertiary)
            }
        } else if let error = instance.lastError {
            HStack(spacing: 6) {
                StatusDot(color: Theme.danger, size: 6)
                Text(error.message)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                if let repair = error.repairTitle {
                    Button(repair) { repairAction(instance, error) }
                        .buttonStyle(.plain)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.accentText)
                        .pointerCursor()
                        .disabled(isSnapshot)
                }
            }
        } else if !instance.isEnabled {
            HStack(spacing: 6) {
                StatusDot(color: Theme.Neutral.n300, size: 6)
                Text("Paused").font(Typography.caption).foregroundStyle(Theme.textTertiary)
            }
        } else {
            HStack(spacing: 6) {
                StatusDot(color: Theme.success, size: 6)
                Text(calendarScopeDescription(instance))
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// What this instance is bound to — the thing the old UI couldn't say, because
    /// every calendar connector read every calendar.
    private func calendarScopeDescription(_ instance: ConnectorInstance) -> String {
        guard let identifiers = instance.config.calendarIdentifiers else { return "Connected" }
        if identifiers.isEmpty { return "Reading every calendar on this Mac" }
        return "Reading \(identifiers.count) calendar\(identifiers.count == 1 ? "" : "s")"
    }

    /// `ImageRenderer` can't draw AppKit-backed controls, and `Menu` is one — it comes
    /// out as a placeholder glyph. Substitute a static stand-in during a snapshot
    /// render, same as `VocabularyEditor` and the hotkey picker do.
    @ViewBuilder
    private func menu(for instance: ConnectorInstance) -> some View {
        if isSnapshot {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 20)
        } else {
            liveMenu(for: instance)
        }
    }

    private func liveMenu(for instance: ConnectorInstance) -> some View {
        Menu {
            Button("Rename\u{2026}") { renaming = instance }
            if instance.descriptor.isSystemBacked {
                Button("Choose calendars\u{2026}") { editingCalendars = instance }
            }
            // A credential-bearing connection can have its secret replaced in place.
            // Without this the only fix for a rotated token was Remove + add again.
            if canReconnect(instance) {
                Button("Reconnect\u{2026}") { reconnecting = instance }
            }
            Button("Test connection") { testConnection(instance) }
                .disabled(testing != nil)
            if store.instances(of: instance.kind).count > 1, !store.isDefault(instance.id) {
                Button("Make default") { store.setDefault(instance.id) }
            }
            Divider()
            Button("Remove", role: .destructive) {
                store.remove(instance.id)
                refreshToday()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
            if canReconnect(instance) {
                reconnecting = instance
            } else {
                isAddingConnector = true
            }
        case .rateLimited, .unreachable:
            break
        }
    }

    /// Whether the credential can be replaced in place: the kind has fields to fill
    /// and an implementation to check them against. A system-backed calendar has no
    /// credential, and a signed-in Google instance is repaired by signing in again,
    /// not by pasting anything.
    private func canReconnect(_ instance: ConnectorInstance) -> Bool {
        !instance.descriptor.isSystemBacked
            && !instance.descriptor.fields.isEmpty
            && ProviderRegistry.hasProvider(for: instance.kind)
    }

    /// Check a saved connection against the real provider, now.
    ///
    /// The row could only ever report the failure of whatever last happened to read
    /// through it, so a connection that had never been used since it was added — or
    /// one broken since the last read — looked healthy. This asks.
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nothing on your calendar today")
                            .font(Typography.headline).tracking(Typography.headlineTracking).foregroundStyle(Theme.textPrimary)
                        Text("You're clear. Ask \u{201C}what's my day\u{201D} anytime.")
                            .font(Typography.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
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

    // MARK: - Ask about your day

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Ask about your day")
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hold \(ModifierChord.command.compactName) and ask — \u{201C}what's my day?\u{201D} — and the answer drops into the notch instead of being typed. Name a connector out loud (\u{201C}what's on my work calendar\u{201D}) to narrow it; ask plainly and every calendar is merged.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Same chord files notes and reminders, and runs anything your connectors can do. It's the one way in to the assistant — holding your push-to-talk key on its own always just dictates.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            }

            if calendarNeedsAccess { calendarAccessCard }
        }
    }

    /// Shown when a calendar connector exists but macOS calendar access isn't granted
    /// yet — the one thing standing between a connection and real data.
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
