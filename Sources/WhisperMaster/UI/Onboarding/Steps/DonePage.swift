import SwiftUI

/// Step 6 — confirmation plus the live voice-engine status (it may still be
/// downloading in the background). The ambient waveform bookends the flow.
struct DonePage: View {
    let state: AppState
    let retryEngine: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Toggled once on appear to fire the checkmark's one-shot bounce.
    @State private var celebrate = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Theme.success.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(Theme.success)
                    .symbolEffect(.bounce, value: celebrate)
            }
            .onAppear { if !reduceMotion { celebrate.toggle() } }
            VStack(spacing: 8) {
                Text("You're all set")
                    .font(Typography.sans(30, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(engineReady
                     ? "The voice engine is downloaded and loaded. Hold your push-to-talk key and start dictating."
                     : "Hold your push-to-talk key and start dictating. We're finishing the voice engine in the background.")
                    .font(Typography.sans(15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            OnboardingWaveform(ambient: true)
                .frame(width: 240, height: 26)

            statusCard
                .frame(maxWidth: 440)

            Spacer()
        }
    }

    // MARK: Voice engine status

    private var engineReady: Bool { state.preparedEngine == state.selectedEngine }
    private var enginePreparing: Bool { state.preparingEngine != nil }
    private var engineFailed: Bool {
        guard !engineReady, !enginePreparing else { return false }
        if case .failed = state.phase { return true }
        return false
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                if let detail = statusDetail {
                    Text(detail)
                        .font(Typography.monoSmall)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer(minLength: 0)

            if engineFailed {
                PrimaryButton(title: "Retry") { retryEngine() }
            } else if enginePreparing {
                Text("\(Int((state.download?.fractionCompleted ?? 0) * 100))%")
                    .font(Typography.sans(15, .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onboardingCard(highlighted: engineReady, radius: 14)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if engineReady {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.success)
        } else if engineFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.accent)
        } else {
            ProgressView().controlSize(.small).tint(Theme.accent)
        }
    }

    private var statusTitle: String {
        if engineReady { return "Voice engine ready" }
        if engineFailed { return "Voice engine setup failed" }
        return "Setting up \(state.selectedEngine.displayName) voice engine…"
    }

    private var statusDetail: String? {
        if engineReady { return state.selectedEngine.userFacingName }
        if engineFailed { return "Check your connection and try again." }
        return state.download?.detail ?? "Downloading \(state.selectedEngine.estimatedDownloadSize)…"
    }
}
