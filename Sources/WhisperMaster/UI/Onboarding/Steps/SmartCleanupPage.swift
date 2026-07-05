import SwiftUI

/// Optional onboarding step offering the on-device "smart cleanup" model.
///
/// The in-card toggle flips `llmCleanupEnabled` (which starts the background
/// download via the refresh-loop reconcile) and shows live status right here —
/// downloading %, then "Ready" — so the user can watch it land before moving on.
/// The footer's "Skip"/"Continue" handles navigation. Either way dictation works
/// immediately; the model only ever adds polish once it's ready.
struct SmartCleanupPage: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.15))
                    .frame(width: 60, height: 60)
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            VStack(spacing: 7) {
                KickerLabel("Optional")
                Text("Smart cleanup")
                    .font(Typography.sans(24, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("A small on-device model that fixes spoken self-corrections and false starts — so \u{201C}three no wait four\u{201D} comes out as \u{201C}four\u{201D}.")
                    .font(Typography.sans(15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }

            VStack(alignment: .leading, spacing: 8) {
                OnboardingBullet(text: "Runs fully on your Mac. Nothing is sent anywhere.")
                OnboardingBullet(text: "About 1.8 GB, downloaded quietly in the background.")
                OnboardingBullet(text: "Dictation works right away while it downloads.")
            }
            .frame(maxWidth: 440, alignment: .leading)

            toggleCard
                .frame(maxWidth: 440)

            Text("Change this anytime in Settings \u{203A} Voice engine.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Toggle + live status

    private var toggleCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Smart cleanup")
                        .font(Typography.bodyMedium)
                        .foregroundStyle(Theme.textPrimary)
                    statusLine
                }
                Spacer(minLength: 8)
                ThemeToggle(isOn: $state.llmCleanupEnabled)
            }

            if let download = state.cleanupModelDownload {
                ProgressView(value: download.fractionCompleted)
                    .tint(Theme.accent)
            }
        }
        .padding(14)
        .onboardingCard(highlighted: state.cleanupModelReady)
    }

    @ViewBuilder
    private var statusLine: some View {
        if !state.llmCleanupEnabled {
            statusText("Off", color: Theme.textTertiary)
        } else if state.cleanupModelReady {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                statusText("Ready to use", color: Theme.success)
            }
        } else if let download = state.cleanupModelDownload {
            statusText("Downloading… \(Int(download.fractionCompleted * 100))%", color: Theme.textSecondary)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                statusText("Getting ready…", color: Theme.textSecondary)
            }
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(color)
    }
}
