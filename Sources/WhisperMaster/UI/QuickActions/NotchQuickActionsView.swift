import SwiftUI

/// The quick-actions band: what the notch holds when you rest the pointer on it.
///
/// Two columns — **reminders** ahead of you and **notes** you touched last — over a
/// row of the three things you'd otherwise open the window for. It is a *glance plus
/// one tap*, not a second Notes app: three rows a column, one action each, and the
/// only mutation available inline is ticking a reminder off — and back on, since a
/// bezel panel has no undo affordance of its own (the one action that
/// needs no typing). Anything that needs a keyboard hands off to the real window,
/// because this is a non-activating panel on the bezel and text has no business here.
///
/// Same molded `NotchShape`, same pinned-ink treatment as the dictation surface and
/// the onboarding band; `.onDarkSurface()` at the root is what puts the button ladder
/// on `Theme.Notch` tokens.
struct NotchQuickActionsView: View {
    let model: NotchQuickActionsModel
    var geometry: NotchGeometry = .none
    var layout: NotchQuickActionsLayout = NotchQuickActionsLayout()
    /// Opens Settings → Notes & Reminders, optionally straight into a fresh editor.
    var onOpenNotes: (NotesComposerRequest?) -> Void = { _ in }
    /// Opens the Settings window — the gear in the header row.
    var onOpenSettings: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = NotchShape(
            topConcaveRadius: layout.topConcaveRadius,
            bottomCornerRadius: layout.bottomCornerRadius
        )

        VStack(spacing: 0) {
            // Camera dead-zone — nothing renders behind the physical notch. Hittable
            // here (unlike the dictation surface): the pointer resting on the notch
            // is what holds this panel open, so the strip it rests on has to count.
            Color.clear
                .frame(height: geometry.notchHeight)

            band
                .frame(height: layout.thickness(rows: model.visibleRowCount))
        }
        .frame(width: layout.surfaceWidth(for: geometry), alignment: .top)
        .background { shape.fill(Theme.Notch.surface) }
        .clipShape(shape)
        .onDarkSurface()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick actions")
    }

    // MARK: - Band

    private var band: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            header
            HStack(alignment: .top, spacing: Theme.Space.lg) {
                column(
                    title: "Next up",
                    isEmpty: model.reminders.isEmpty,
                    emptyLine: "Nothing due."
                ) {
                    ForEach(model.reminders) { reminder in
                        ReminderQuickRow(
                            reminder: reminder,
                            isChecked: model.isChecked(reminder.id)
                        ) {
                            model.toggle(reminder)
                        }
                    }
                }
                column(
                    title: "Recent notes",
                    isEmpty: model.recentNotes.isEmpty,
                    emptyLine: "No notes yet."
                ) {
                    ForEach(model.recentNotes) { note in
                        NoteQuickRow(note: note) { onOpenNotes(nil) }
                    }
                }
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.md)
        .padding(.horizontal, Theme.Space.lg)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Quick actions")
                .font(Typography.notchTitle)
                .foregroundStyle(Theme.Notch.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Space.sm)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .iconButton(size: 22, tooltip: "Open Settings")
            .accessibilityLabel("Open Settings")
        }
    }

    /// One column: a quiet label over up to three rows, or a single honest line when
    /// there's nothing in it. Both columns keep the same width so the band reads as
    /// two halves rather than as one list that overflowed.
    @ViewBuilder
    private func column<Rows: View>(
        title: String,
        isEmpty: Bool,
        emptyLine: String,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(Typography.notchCaption)
                .tracking(0.6)
                .foregroundStyle(Theme.Notch.textTertiary)
            if isEmpty {
                Text(emptyLine)
                    .font(Typography.notchBody)
                    .foregroundStyle(Theme.Notch.textSecondary)
            } else {
                rows()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.sm) {
            QuickActionButton(title: "New reminder", icon: "bell.badge") {
                onOpenNotes(.reminder)
            }
            QuickActionButton(title: "New note", icon: "square.and.pencil") {
                onOpenNotes(.note)
            }
            Spacer(minLength: Theme.Space.sm)
            QuickActionButton(title: "Open all", icon: "arrow.up.forward") {
                onOpenNotes(nil)
            }
        }
    }
}

// MARK: - Rows

/// A reminder at a glance: tick it off on the left, read it on the right. The
/// checkbox is the one inline mutation the band offers — it needs no keyboard, and
/// "done" is the answer a due reminder is usually waiting for.
///
/// It ticks **both ways**. A ticked row stays in place, struck through, for the
/// rest of the glance (`NotchQuickActionsModel.ticked`) rather than vanishing on
/// the click — on a bezel panel with no undo affordance, a one-way tick means a
/// mis-click can only be fixed by opening the real window.
private struct ReminderQuickRow: View {
    let reminder: ReminderItem
    let isChecked: Bool
    let onToggle: () -> Void

    private var isOverdue: Bool { reminder.dueDate <= Date() }

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onToggle) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isChecked ? Theme.Notch.success : Theme.Notch.text)
            }
            .iconButton(size: 20, tooltip: isChecked ? "Mark not done" : "Mark done")
            .accessibilityLabel(
                isChecked
                    ? "Mark “\(reminder.displayTitle)” not done"
                    : "Mark “\(reminder.displayTitle)” done")

            VStack(alignment: .leading, spacing: 0) {
                Text(reminder.displayTitle)
                    .font(Typography.notchBody)
                    .foregroundStyle(isChecked ? Theme.Notch.textSecondary : Theme.Notch.text)
                    .strikethrough(isChecked)
                Text(isChecked ? "Done" : NotchQuickActionsFormat.due(reminder.dueDate))
                    .font(Typography.notchCaption)
                    .foregroundStyle(
                        isChecked || !isOverdue ? Theme.Notch.textSecondary : Theme.Notch.warning)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)
        }
    }
}

/// A note at a glance. Tapping it opens the real editor — the band has no business
/// holding a text field.
private struct NoteQuickRow: View {
    let note: Note
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 7) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Notch.textTertiary)
                Text(note.displayTitle)
                    .font(Typography.notchBody)
                    .foregroundStyle(Theme.Notch.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Open note “\(note.displayTitle)”")
    }
}

/// The band's action rung: a compact labelled pill on the ink surface. Outlined
/// rather than filled — three equal-weight ways out of the panel, none of them the
/// one true action, so none of them gets the ember pill.
private struct QuickActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(Typography.sans(12, .semibold))
            }
        }
        .outlinedButton()
        .accessibilityLabel(title)
    }
}

// MARK: - Formatting

/// Due-date wording for the band, which has room for three words, not a sentence:
/// "9:30 AM" today, "Tomorrow 9:30 AM", "Mon 9:30 AM" inside the week, a date
/// beyond it, and "Overdue" once it's past.
enum NotchQuickActionsFormat {
    static func due(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if date <= now { return "Overdue" }
        let time = timeFormatter.string(from: date)
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        let days = calendar.dateComponents([.day], from: now, to: date).day ?? 0
        if days < 7 { return "\(weekdayFormatter.string(from: date)) \(time)" }
        return dayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()
}
