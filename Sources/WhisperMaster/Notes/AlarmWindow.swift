import SwiftUI

/// The SwiftUI content for the looping-alarm alert window (hosted by
/// `AlarmController`). Daylight chrome to match the settings/onboarding windows.
struct AlarmView: View {
    let reminder: ReminderItem
    let onSnooze: () -> Void
    let onDone: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse, options: .repeating)
                .padding(.top, Theme.Space.sm)

            VStack(spacing: Theme.Space.xs) {
                Text(reminder.displayTitle)
                    .font(Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                if !reminder.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(reminder.body)
                        .font(Typography.body)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(Self.timeFormatter.string(from: reminder.dueDate))
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, Theme.Space.lg)

            Spacer(minLength: 0)

            HStack(spacing: Theme.Space.md) {
                SecondaryButton(title: "Snooze 5 min", icon: "clock.arrow.circlepath", action: onSnooze)
                PrimaryButton(title: "Done", icon: "checkmark", action: onDone)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasGradient.ignoresSafeArea())
    }
}
