import SwiftUI

/// Optional onboarding step offering the on-device "smart cleanup" model.
/// Opting in flips `llmCleanupEnabled` (which starts the background download)
/// and advances; the footer's "Skip" declines. Either way dictation works right
/// away — the model only ever adds polish once it's ready.
struct SmartCleanupPage: View {
    let enabled: Bool
    let onEnable: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.15))
                    .frame(width: 92, height: 92)
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            VStack(spacing: 8) {
                KickerLabel("Optional")
                Text("Smart cleanup")
                    .font(Typography.sans(30, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Add a small on-device model that tidies what you say. It fixes self-corrections and false starts, so \u{201C}three no wait four\u{201D} just comes out as \u{201C}four\u{201D}.")
                    .font(Typography.sans(15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            VStack(alignment: .leading, spacing: 12) {
                OnboardingBullet(text: "Runs fully on your Mac. Nothing is sent anywhere.")
                OnboardingBullet(text: "About 1.8 GB, downloaded quietly in the background.")
                OnboardingBullet(text: "Dictation works right away while it downloads.")
            }
            .frame(maxWidth: 460, alignment: .leading)

            if enabled {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                    Text("On — downloading in the background")
                        .font(Typography.sans(14, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                PrimaryButton(title: "Turn on smart cleanup", action: onEnable)
            }

            Text("You can change this anytime in Settings \u{203A} Voice engine.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)

            Spacer()
        }
    }
}
