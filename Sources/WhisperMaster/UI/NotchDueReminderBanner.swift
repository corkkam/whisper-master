import SwiftUI

/// A reminder that has come due, announced **in the notch** rather than as a
/// system notification banner.
///
/// This is the `.notification` alert style's surface. Everything else the app
/// says already happens here, so a scheduled reminder arriving in Notification
/// Centre — stacked with mail and Slack, and easy to swipe past — was the one
/// thing that landed somewhere else. The alarm style still takes its own focused
/// window; this is the quiet half.
///
/// It carries the answer a due reminder is usually waiting for: a **checkbox**,
/// which ticks it off without opening anything, and un-ticks it again while the
/// band is still down (the tick is one click on a bezel, so undo has to be one
/// click too). Tapping the text opens Notes & Reminders — what tapping the old
/// notification did. Both make it interactive, so the pill panel takes clicks
/// while it's up (`DictationPillWindow.setInteractive`).
struct NotchDueReminderBanner: View {
    let reminder: ReminderItem
    /// Whether the user has already ticked it off. Owned by `AppState`, not read
    /// back off the store — see `AppState.dueReminderCompleted`.
    var isCompleted: Bool = false
    /// Tick it off / put it back.
    var onToggle: () -> Void = {}
    /// Open Settings → Notes & Reminders.
    var onOpen: () -> Void = {}

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// The body when the reminder carries one, otherwise the time it was set
    /// for — the second line is never empty, and "Reminder" alone says nothing
    /// the bell hasn't already. Once ticked it says so instead: the strikethrough
    /// alone is easy to miss at bezel size. (It doesn't spell out the undo — the
    /// tick is what reverses it, while tapping this text opens Notes & Reminders.)
    private var subtitle: String {
        if isCompleted { return "Done" }
        let body = reminder.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty else { return body }
        return "Due \(Self.timeFormatter.string(from: reminder.dueDate))"
    }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "bell.fill")
                .font(Typography.notchTitle)
                .foregroundStyle(Theme.Notch.text.opacity(0.9))

            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.displayTitle)
                    .font(Typography.notchTitle)
                    .foregroundStyle(isCompleted ? Theme.Notch.textSecondary : Theme.Notch.text)
                    .strikethrough(isCompleted)

                Text(subtitle)
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.textSecondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The text is the "open it properly" target; the checkbox beside it
            // keeps its own tap, so the two never fight over one click.
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Reminder. \(reminder.displayTitle). \(subtitle)")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens Notes & Reminders")

            checkbox
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(maxWidth: .infinity)
    }

    /// The tick. Filled once checked so the state reads from the glyph alone, and
    /// tinted with the success hue the delivered beat uses — this is the band's one
    /// "that's handled" signal.
    private var checkbox: some View {
        Button(action: onToggle) {
            Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isCompleted ? Theme.Notch.success : Theme.Notch.text.opacity(0.75))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(
            isCompleted
                ? "Mark “\(reminder.displayTitle)” not done"
                : "Mark “\(reminder.displayTitle)” done")
    }
}
