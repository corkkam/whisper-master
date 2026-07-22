import SwiftUI

/// The "Connectors" tab: link calendars, mail and chat so the app can answer
/// "what's my day" from the notch.
///
/// Calendar connectors (iCal / Google Calendar / Outlook) read live through
/// macOS EventKit — the system Calendar app already aggregates those accounts, so
/// they work with no OAuth once calendar access is granted. Gmail, Slack and the
/// mail side of Outlook are OAuth and show a "needs setup" state until credentials
/// are configured (`OAuthConnectorConfig`).
struct ConnectorsSettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot

    private var store: ConnectorStore { state.connectorStore }

    /// Today's real events, loaded from EventKit when calendar access is granted.
    @State private var todayEvents: [DayEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            askSection
            if showTodaySection { todaySection }
            featuredSection
            popularSection
        }
        .onAppear {
            refreshCalendarAccess()
            refreshToday()
        }
    }

    // MARK: - Today (live EventKit preview)

    /// Show the live preview once a calendar connector is on and access is granted
    /// (or always, in the snapshot renderer, with mock events).
    private var showTodaySection: Bool {
        isSnapshot || (store.anyCalendarEnabled && store.calendarAccessGranted)
    }

    private var displayEvents: [DayEvent] {
        isSnapshot ? Self.mockEvents : todayEvents
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Today")
                Spacer()
                Text("Live from your calendar")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            let events = displayEvents
            if events.isEmpty {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nothing on your calendar today")
                            .font(Typography.headline).foregroundStyle(Theme.textPrimary)
                        Text("You're clear. Ask “what's my day” anytime.")
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
                    .font(Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .strikethrough(!event.isUpcoming)
                if !event.calendarTitle.isEmpty {
                    let source = event.sourceTitle.isEmpty ? event.calendarTitle
                        : "\(event.calendarTitle) · \(event.sourceTitle)"
                    Text(source)
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
        todayEvents = CalendarConnector.shared.isAuthorized ? CalendarConnector.shared.todaysEvents() : []
    }

    // MARK: - Ask about your day

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Ask about your day")
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hold your day-query key and ask — “what's my day?”, “what's on my calendar?” — and the answer drops into the notch. You can also just say it on the normal dictation key.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                RowDivider()
                SettingsRow("Ask-about-your-day key",
                            subtitle: "A separate push-to-talk key that always asks your connectors instead of typing.") {
                    dayQueryHotkeyMenu
                }
            }

            if calendarNeedsAccess {
                calendarAccessCard
            }
        }
    }

    /// Shown when a calendar connector is on but macOS calendar access isn't
    /// granted yet — the one thing standing between the toggle and real data.
    private var calendarAccessCard: some View {
        SettingsCard {
            SettingsRow("Allow calendar access",
                        subtitle: "Your calendar stays on this Mac. It's only read to summarise your day.") {
                SecondaryButton(title: "Allow", icon: "calendar") {
                    Task {
                        let granted = await CalendarConnector.shared.requestAccess()
                        store.calendarAccessGranted = granted
                        refreshToday()
                    }
                }
                .disabled(isSnapshot)
            }
        }
    }

    // MARK: - Connector lists

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Connectors")
            SettingsCard {
                ForEach(Array(ConnectorKind.featured.enumerated()), id: \.element) { index, kind in
                    if index > 0 { RowDivider() }
                    connectorRow(kind)
                }
            }
        }
    }

    private var popularSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Popular connectors")
            SettingsCard {
                ForEach(Array(ConnectorKind.popular.enumerated()), id: \.element) { index, kind in
                    if index > 0 { RowDivider() }
                    connectorRow(kind)
                }
            }
        }
    }

    private func connectorRow(_ kind: ConnectorKind) -> some View {
        HStack(spacing: 14) {
            Image(systemName: kind.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(kind.displayName)
                        .font(Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    statusChip(for: kind)
                }
                Text(kind.blurb)
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            ThemeToggle(
                isOn: Binding(
                    get: { store.isEnabled(kind) },
                    set: { toggle(kind, $0) }
                ),
                label: kind.displayName)
        }
        .padding(.vertical, 15)
    }

    /// A small status chip: "Live" for a granted calendar connector, "Needs setup"
    /// for an OAuth connector without credentials — so the UI never implies an
    /// unconfigured connector is actually fetching.
    @ViewBuilder
    private func statusChip(for kind: ConnectorKind) -> some View {
        if store.isEnabled(kind) {
            if kind.auth == .system {
                Chip(store.calendarAccessGranted ? "Live" : "Allow access")
            } else if !OAuthConnectorConfig.isConfigured(kind) {
                Chip("Needs setup")
            } else {
                Chip("Connected")
            }
        }
    }

    // MARK: - Actions

    private func toggle(_ kind: ConnectorKind, _ on: Bool) {
        store.setEnabled(kind, on)
        // Turning on a calendar connector is the natural moment to ask for
        // calendar access (if we haven't yet) — otherwise the day summary would
        // silently have nothing to read.
        if on, kind.auth == .system, CalendarConnector.shared.isUndetermined {
            Task {
                let granted = await CalendarConnector.shared.requestAccess()
                store.calendarAccessGranted = granted
                refreshToday()
            }
        } else if kind.auth == .system {
            refreshToday()
        }
    }

    private func refreshCalendarAccess() {
        store.calendarAccessGranted = CalendarConnector.shared.isAuthorized
    }

    private var calendarNeedsAccess: Bool {
        store.anyCalendarEnabled && !store.calendarAccessGranted
    }

    // MARK: - Day-query hotkey picker

    @ViewBuilder
    private var dayQueryHotkeyMenu: some View {
        if isSnapshot {
            HStack(spacing: 9) {
                Text(state.dayQueryHotkey.compactName)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        } else {
            Picker("", selection: Binding(
                get: { state.dayQueryHotkey },
                set: { viewModel.updateDayQueryHotkey($0) }
            )) {
                ForEach(HotkeyManager.HotkeyOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.accent)
            .fixedSize()
        }
    }

    // MARK: - Statics

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// Believable events for the headless snapshot renderer (no calendar access
    /// there). Times are relative so they always look like "today".
    static var mockEvents: [DayEvent] {
        let now = Date()
        func at(_ hoursFromNow: Double, _ minutes: Double = 60) -> (Date, Date) {
            let start = now.addingTimeInterval(hoursFromNow * 3600)
            return (start, start.addingTimeInterval(minutes * 60))
        }
        let a = at(-1), b = at(0.5, 30), c = at(3)
        return [
            DayEvent(id: "m1", title: "Team stand-up", start: a.0, end: a.1, isAllDay: false,
                     calendarTitle: "Work", sourceTitle: "Google"),
            DayEvent(id: "m2", title: "Design review — Daylight tokens", start: b.0, end: b.1, isAllDay: false,
                     calendarTitle: "Work", sourceTitle: "Exchange"),
            DayEvent(id: "m3", title: "1:1 with Sam", start: c.0, end: c.1, isAllDay: false,
                     calendarTitle: "Personal", sourceTitle: "iCloud"),
        ]
    }
}
