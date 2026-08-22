import SwiftUI

/// Today, as one ordered column: events and reminders interleaved by time.
///
/// This is the reason the quick-actions panel exists, and it replaced a reminders
/// column that sat beside a notes column. "What is on my plate" is **one**
/// question; splitting it by which app the row came from made the reader merge two
/// lists by eye, and left the calendar — which the app already reads for the spoken
/// day summary — out of the surface built for the question entirely.
///
/// Three rules the shape depends on:
///
/// - **What has gone is dimmed, not dropped.** A day whose morning has been
///   deleted reads as an empty day, and the row you just finished is the one that
///   orients you in the list.
/// - **The checkbox ticks both ways**, the same affordance the notch banner and the
///   ambient row use, with the pre-tick snapshot held by
///   `NotchQuickActionsModel.ticked` — a bezel panel has no undo of its own, so a
///   one-way tick means a mis-click can only be fixed from the real window.
/// - **Nothing is silently truncated.** Past `NowTimeline.displayLimit` the column
///   says how many rows it left out.
struct NotchDayTimelineColumn: View {
    let rows: [NowTimelineRow]
    let hidden: Int
    let now: Date
    /// Whether a row is showing as ticked off in this glance.
    var isChecked: (UUID) -> Bool = { _ in false }
    var onToggle: (ReminderItem) -> Void = { _ in }
    var onJoin: (URL) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("TODAY")
                .font(Typography.notchCaption)
                .tracking(0.6)
                .foregroundStyle(Theme.Notch.textTertiary)
                .accessibilityAddTraits(.isHeader)

            if rows.isEmpty {
                Text("Nothing on today.")
                    .font(Typography.notchBody)
                    .foregroundStyle(Theme.Notch.textSecondary)
            } else {
                ForEach(rows) { row in
                    NotchDayTimelineRow(
                        row: row,
                        now: now,
                        isChecked: row.reminder.map { isChecked($0.id) } ?? false,
                        onToggle: { if let reminder = row.reminder { onToggle(reminder) } },
                        onJoin: onJoin)
                }
                if hidden > 0 {
                    // Said out loud rather than truncated in silence: a list that
                    // stops at five reads as a day that stops at five.
                    Text("\(hidden) more today")
                        .font(Typography.notchCaption)
                        .foregroundStyle(Theme.Notch.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line of the day. Time on the left, then what it is, then the one thing you
/// might do about it.
struct NotchDayTimelineRow: View {
    let row: NowTimelineRow
    let now: Date
    var isChecked: Bool = false
    var onToggle: () -> Void = {}
    var onJoin: (URL) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 8) {
            Text(timeLabel)
                .font(Typography.notchCaption)
                .foregroundStyle(Theme.Notch.textTertiary)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)

            marker

            Text(row.title)
                .font(Typography.notchBody)
                .foregroundStyle(isChecked ? Theme.Notch.textSecondary : Theme.Notch.text)
                .strikethrough(isChecked)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            trailing
        }
        .opacity(row.isPast && !isChecked ? 0.45 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
    }

    /// "All day" for an all-day event, the clock time for a timed one, and
    /// `NotchQuickActionsFormat.due` for a reminder — which is what turns a
    /// reminder carried over from last week into "Overdue" rather than a clock
    /// time on a row sitting in a column headed Today.
    ///
    /// Never a countdown. The ambient row is where the ticking number lives; a
    /// column of them would be five things counting at once.
    private var timeLabel: String {
        if row.isAllDay { return "All day" }
        if row.reminder != nil { return NotchQuickActionsFormat.due(row.at, now: now) }
        return NowPhrase.clock.string(from: row.at)
    }

    /// A checkbox for a reminder — the column's one inline mutation — and a
    /// coloured dot for an event. Live events get the amber the ambient row uses
    /// for the same state, so the two surfaces agree at a glance.
    @ViewBuilder
    private var marker: some View {
        if row.reminder != nil {
            Button(action: onToggle) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isChecked ? Theme.Notch.success : Theme.Notch.accent)
            }
            .iconButton(size: 20, tooltip: isChecked ? "Mark not done" : "Mark done")
            .accessibilityLabel(
                isChecked ? "Mark “\(row.title)” not done" : "Mark “\(row.title)” done")
        } else {
            Circle()
                .fill(eventTint)
                .frame(width: 6, height: 6)
                .frame(width: 20)
        }
    }

    private var eventTint: Color {
        guard let event = row.event else { return Theme.Notch.textTertiary }
        if event.isAllDay { return Theme.Notch.textTertiary }
        if event.start <= now && event.end > now { return Theme.Notch.warning }
        return row.isPast ? Theme.Notch.textTertiary : Theme.Notch.textSecondary
    }

    /// Join if the invitation carried a link, otherwise where the row came from.
    @ViewBuilder
    private var trailing: some View {
        if let url = row.event?.joinURL, !row.isPast {
            // The same hand-tuned pill the ambient row uses, not `.outlinedButton()`.
            // The ladder's pill carries the window's button geometry, which on a
            // 28pt timeline row was half again the height of its neighbours and
            // made the one joinable meeting sit in a gap of its own.
            NotchJoinButton(title: row.title) { onJoin(url) }
        } else {
            Text(row.source)
                .font(Typography.notchCaption)
                .foregroundStyle(Theme.Notch.textTertiary)
                .lineLimit(1)
        }
    }

    private var spoken: String {
        "\(timeLabel), \(row.title), \(row.source)" + (isChecked ? ", done" : "")
    }
}
