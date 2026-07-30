import ClerkKit
import SwiftUI

/// The **Today** screen — a warm daily glance built from *real* data only: the
/// live EventKit calendar agenda and the user's own reminders. No weather /
/// unread-mail / AI briefing (there's no backend for those), so the screen stays
/// honest — it shows what the app genuinely knows.
struct TodayView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState
    var openConnectors: () -> Void = {}

    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var events: [DayEvent] = []
    @State private var calendarAuthorized = false
    @State private var calendarUndetermined = true

    private var isRecording: Bool { state.phase == .recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            greeting

            HStack(alignment: .top, spacing: 16) {
                agendaCard
                remindersCard
            }

            askRow
        }
        .onAppear(perform: refreshCalendar)
    }

    // MARK: Greeting header

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dateKicker.uppercased())
                .font(Typography.kicker)
                .tracking(2.0)
                .foregroundStyle(Theme.accentText)
            Text("\(timeOfDayGreeting)\(greetingName.map { ", \($0)" } ?? "")")
                .font(Typography.largeTitle).tracking(Typography.largeTitleTracking)
                .foregroundStyle(Theme.textPrimary)
            Text("Here's the shape of your day. Talk to me any time.")
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Agenda

    private var agendaCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(icon: "calendar", title: "Today's agenda")

            if !calendarAuthorized {
                connectCalendarPrompt
            } else if !hasCalendarConnector {
                // Access granted but nothing bound yet. Distinct from "nothing on
                // today" — an empty agenda because no calendar is connected is a
                // setup gap, and saying "enjoy the open space" would be a lie.
                emptyLine("No calendar connected yet. Add one in Connectors to see your day here.")
            } else if events.isEmpty {
                emptyLine("Nothing on your calendar today. Enjoy the open space.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(events.prefix(6)) { event in
                        agendaRow(event)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassCard()
    }

    private func agendaRow(_ event: DayEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(event.isAllDay ? "all day" : timeString(event.start))
                .font(Typography.sans(12, .bold))
                .monospacedDigit()
                .foregroundStyle(event.isUpcoming ? Theme.accentText : Theme.textTertiary)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(Typography.sans(13.5, .medium))
                    .foregroundStyle(event.isUpcoming ? Theme.textPrimary : Theme.textSecondary)
                    .strikethrough(!event.isUpcoming, color: Theme.textTertiary)
                    .lineLimit(2)
                // Only worth the line when more than one calendar is connected —
                // that's when "which one?" is a real question.
                if showsProvenance, !event.instanceLabel.isEmpty {
                    Text(event.instanceLabel)
                        .font(Typography.sans(11.5, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var connectCalendarPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(calendarUndetermined
                 ? "Connect your calendar and Whisper can show your day here."
                 : "Calendar access is off. Turn it on in System Settings → Privacy → Calendars.")
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if calendarUndetermined {
                    Button(action: requestCalendar) {
                        chipLabel("Connect calendar", filled: true)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
                Button(action: openConnectors) {
                    chipLabel("Open Connectors", filled: false)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: Reminders

    private var remindersCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(icon: "checklist", title: "Reminders")

            let items = todaysReminders
            if items.isEmpty {
                emptyLine("You're all caught up. Nothing due.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items.prefix(6)) { reminder in
                        reminderRow(reminder)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassCard()
    }

    private func reminderRow(_ reminder: ReminderItem) -> some View {
        Button {
            withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.toggle)) {
                state.notesStore.completeReminder(reminder.id)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(reminder.isCompleted ? Theme.accent : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reminder.displayTitle)
                        .font(Typography.sans(13.5, .medium))
                        .foregroundStyle(reminder.isCompleted ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(reminder.isCompleted, color: Theme.textTertiary)
                        .lineLimit(2)
                    Text(dueLabel(reminder))
                        .font(Typography.caption)
                        .foregroundStyle(Theme.accentText)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: Ask row

    private var askRow: some View {
        HStack(spacing: 10) {
            Text("Ask me to")
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Button {
                if isRecording { viewModel.stopRecording() } else { viewModel.startRecording() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "mic.fill").font(.system(size: 12, weight: .semibold))
                    Text(isRecording ? "Stop" : "Start talking").font(Typography.bodyMedium)
                }
                .foregroundStyle(Theme.accentOn)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.accent)
                        .shadow(color: Theme.accent.opacity(0.4), radius: 8, x: 0, y: 4)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Spacer(minLength: 0)
        }
    }

    // MARK: Bits

    private func cardHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(title.uppercased())
                .font(Typography.label)
                .tracking(1.4)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(Typography.subheadline)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private func chipLabel(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(filled ? Theme.accentOn : Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(filled ? Theme.accentFill : Theme.surfaceGlass)
                    .overlay(Capsule().strokeBorder(filled ? Color.clear : Theme.line, lineWidth: 1))
            )
    }

    // MARK: Data

    private var todaysReminders: [ReminderItem] {
        let cal = Calendar.current
        let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        // Incomplete due today or overdue, then the rest of today's incomplete,
        // sorted by due date. Keep it to what's actionable now.
        return state.notesStore.visibleReminders
            .filter { !$0.isCompleted && $0.dueDate < endOfDay }
            .sorted { $0.dueDate < $1.dueDate }
    }

    /// Whether any calendar connector instance exists to read from at all.
    private var hasCalendarConnector: Bool {
        isSnapshot || state.connectorStore.hasReadableCalendar
    }

    /// Show the connector label under each event only when there's more than one
    /// calendar instance to disambiguate between.
    private var showsProvenance: Bool {
        isSnapshot || state.connectorStore.readable(providing: .events).count > 1
    }

    /// Read through the instance fan-out rather than straight from EventKit, so the
    /// agenda respects which calendars each connector is bound to and each row can
    /// name the connector it came from.
    private func refreshCalendar() {
        guard !isSnapshot else { return }
        let cal = CalendarConnector.shared
        calendarAuthorized = cal.isAuthorized
        calendarUndetermined = cal.isUndetermined
        events = cal.isAuthorized
            ? DaySummaryService.build(store: state.connectorStore).events
            : []
    }

    private func requestCalendar() {
        Task { @MainActor in
            let granted = await CalendarConnector.shared.requestAccess()
            state.connectorStore.calendarAccessGranted = granted
            if granted {
                for kind in ConnectorKind.allCases {
                    state.connectorStore.clearErrors(ofKind: kind, matching: .needsCalendarAccess)
                }
            }
            refreshCalendar()
        }
    }

    // MARK: Formatting

    private var timeOfDayGreeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case ..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var greetingName: String? {
        guard !isSnapshot else { return "Alex" }
        guard let first = Clerk.shared.user?.firstName?.trimmingCharacters(in: .whitespaces),
              !first.isEmpty else { return nil }
        return first
    }

    private var dateKicker: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE · MMMM d"
        return f.string(from: Date())
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    private func dueLabel(_ reminder: ReminderItem) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(reminder.dueDate) {
            f.dateFormat = "h:mm a"
            return "Due \(f.string(from: reminder.dueDate))"
        }
        if reminder.dueDate < Date() { return "Overdue" }
        f.dateFormat = "EEE h:mm a"
        return "Due \(f.string(from: reminder.dueDate))"
    }
}
