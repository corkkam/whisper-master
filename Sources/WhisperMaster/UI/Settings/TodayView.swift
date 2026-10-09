import SwiftUI

/// The Today screen: a warm greeting, quick actions, the real EventKit agenda,
/// and today's to-dos. Only genuinely-known data — no weather, unread mail, or
/// AI briefing (there's no backend for those).
struct TodayView: View {
    @Bindable var state: AppState
    let notes: NotesStore
    let connectors: ConnectorStore
    let account: AccountStore
    var startTalking: () -> Void = {}
    var openConnectors: () -> Void = {}
    var openNotes: () -> Void = {}

    @Environment(\.isSnapshot) private var isSnapshot
    @State private var summary = DaySummary(events: [], calendarAccessGranted: false)
    @State private var showAddTodo = false
    @State private var newTodo = ""

    private var daySummary: DaySummaryService { DaySummaryService(calendar: connectors.calendar) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            greeting
            quickActions
            agendaCard
            remindersCard
        }
        .onAppear { refresh() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        summary = daySummary.build()
    }

    // MARK: Greeting

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 8) {
            KickerLabel(Self.dateKicker)
            Text("\(Self.timeOfDayGreeting), \(account.firstName)")
                .font(Typography.largeTitle)
                .foregroundStyle(Theme.textPrimary)
            Text(agendaSummaryLine)
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var agendaSummaryLine: String {
        if !summary.calendarAccessGranted {
            return "Connect your calendar to see today at a glance."
        }
        let events = summary.events.count
        let todos = notes.dueReminders(asOf: Date()).count
        let eventPart = events == 0 ? "Nothing on the calendar" : "\(events) event\(events == 1 ? "" : "s")"
        let todoPart = todos == 0 ? "no to-dos due" : "\(todos) to-do\(todos == 1 ? "" : "s") due"
        return "\(eventPart) · \(todoPart)."
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            QuickChip(icon: "mic.fill", title: "Start talking", action: startTalking)
            QuickChip(icon: "plus", title: "Add a to-do") { showAddTodo = true }
            QuickChip(icon: "note.text", title: "Open notes", action: openNotes)
        }
    }

    // MARK: Agenda

    private var agendaCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(icon: "calendar", title: "Agenda", trailing: summary.calendarAccessGranted ? Self.dayLabel : nil)

            if !summary.calendarAccessGranted {
                connectCalendarPrompt
            } else if summary.events.isEmpty {
                emptyRow(icon: "calendar", text: "Nothing scheduled today.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(summary.events.enumerated()), id: \.element.id) { index, event in
                        AgendaRow(event: event, isNext: summary.nextEvent()?.id == event.id)
                        if index < summary.events.count - 1 { RowDivider() }
                    }
                }
            }
        }
        .padding(20)
        .glassCard()
    }

    private var connectCalendarPrompt: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentSoft)
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect your calendar")
                    .font(Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Whisper Master reads today's events on-device to build your agenda.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            PrimaryButton(title: "Connect", icon: "arrow.right") {
                Task {
                    await connectors.connect(.calendar)
                    refresh()
                }
            }
        }
        .padding(.top, 16)
    }

    // MARK: Reminders

    private var remindersCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(icon: "checklist", title: "To-dos", trailing: nil)

            if showAddTodo || !isSnapshot {
                addTodoField.padding(.top, showAddTodo ? 14 : 0)
                    .frame(height: showAddTodo ? nil : 0, alignment: .top)
                    .opacity(showAddTodo ? 1 : 0)
                    .clipped()
            }

            let due = notes.dueReminders(asOf: Date())
            if due.isEmpty {
                emptyRow(icon: "checkmark.circle", text: "No to-dos due today. Nicely done.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(due.enumerated()), id: \.element.id) { index, reminder in
                        ReminderRow(reminder: reminder) { notes.toggleReminder(reminder.id) }
                        if index < due.count - 1 { RowDivider() }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .glassCard()
    }

    @ViewBuilder
    private var addTodoField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)
            if isSnapshot {
                Text("Add a to-do…").font(Typography.body).foregroundStyle(Theme.textTertiary)
            } else {
                TextField("Add a to-do…", text: $newTodo)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .onSubmit(commitTodo)
            }
            Spacer(minLength: 0)
            Button("Add", action: commitTodo)
                .buttonStyle(GhostButtonStyle())
                .disabled(newTodo.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
        )
    }

    private func commitTodo() {
        let text = newTodo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notes.addReminder(title: text)
        newTodo = ""
    }

    // MARK: Shared bits

    private func cardHeader(icon: String, title: String, trailing: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(Typography.title)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func emptyRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 16)
    }

    // MARK: Formatters

    private static var timeOfDayGreeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Still up"
        }
    }

    private static var dateKicker: String {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date()).uppercased()
    }

    private static var dayLabel: String {
        let f = DateFormatter(); f.dateFormat = "EEE d"
        return f.string(from: Date())
    }
}

/// A rounded glass "quick action" chip.
private struct QuickChip: View {
    let icon: String
    let title: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(Typography.bodyMedium)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassCard(cornerRadius: 12, tint: 0.42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One agenda event row: colored rule, time, title, location.
private struct AgendaRow: View {
    let event: CalendarEvent
    var isNext: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(event.tint)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                if let location = event.location {
                    Text(location)
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(event.timeLabel)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                if isNext {
                    Text("NEXT")
                        .font(Typography.sans(9, .bold))
                        .tracking(1)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accentSoft))
                }
            }
        }
        .padding(.vertical, 12)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A checklist reminder row with a tappable checkbox.
private struct ReminderRow: View {
    let reminder: TodoReminder
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(reminder.isCompleted ? Theme.accent : Theme.textTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(reminder.title)
                .font(Typography.body)
                .foregroundStyle(reminder.isCompleted ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(reminder.isCompleted, color: Theme.textTertiary)
            Spacer(minLength: 8)
            if let due = reminder.dueAt {
                Text(Self.dueFormatter.string(from: due))
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 11)
    }

    private static let dueFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f
    }()
}
