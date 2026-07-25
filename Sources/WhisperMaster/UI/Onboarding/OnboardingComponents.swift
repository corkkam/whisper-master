import SwiftUI

// MARK: - Card chrome

/// Shared boxed-card chrome for onboarding tiles (mic-test box, engine-status
/// card, permission tiles). `highlighted` swaps the hairline for a success tint.
extension View {
    func onboardingCard(highlighted: Bool = false, radius: CGFloat = 16) -> some View {
        modifier(OnboardingCardChrome(highlighted: highlighted, radius: radius))
    }
}

private struct OnboardingCardChrome: ViewModifier {
    let highlighted: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(highlighted ? Theme.success.opacity(0.5) : Theme.stroke, lineWidth: 1)
            )
    }
}

// MARK: - Progress bar

/// Labeled segmented progress for the wizard: one capsule per step (filled up to
/// the current one), with the active step's name and a two-digit "current / total"
/// counter below (the total tracks `OnboardingStep.allCases`, so it can't go stale).
struct OnboardingProgressBar: View {
    /// The steps actually being presented (the full flow, or a partial subset
    /// when only newly-added steps are shown), so the counter can't go stale.
    let steps: [OnboardingStep]
    let step: OnboardingStep

    private var currentIndex: Int { steps.firstIndex(of: step) ?? 0 }

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.element.rawValue) { index, _ in
                    Capsule(style: .continuous)
                        .fill(index <= currentIndex ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.stroke))
                        .frame(height: 4)
                        .frame(maxWidth: .infinity)
                        .animation(.easeInOut(duration: 0.22), value: step)
                }
            }

            HStack {
                Text(step.title.uppercased())
                    .font(Typography.kicker)
                    .tracking(2.2)
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text(String(format: "%02d / %02d", currentIndex + 1, steps.count))
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Waveform signature

/// The voice-waveform motif that threads the whole flow. Two moods: `ambient`
/// draws a calm, static silhouette (Welcome / Done); otherwise it reacts to a
/// live mic `level` and glows in the accent while `active`.
struct OnboardingWaveform: View {
    var level: Float = 0
    var active: Bool = false
    var ambient: Bool = false

    private let barCount = 32

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 4
            let barWidth = max(2, (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(active ? Theme.accent : Theme.strokeStrong)
                        .frame(width: barWidth, height: height(index: index, total: geo.size.height))
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        // Purely decorative motif — the status copy carries the real information,
        // so keep it out of the VoiceOver rotor.
        .accessibilityHidden(true)
    }

    /// Bars taper toward the edges (center-weighted envelope). Ambient mode adds
    /// a fixed sine ripple so the resting shape reads as a waveform, not a flat row.
    private func height(index: Int, total: CGFloat) -> CGFloat {
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        let envelope = 1 - pow(distance, 2)
        if ambient {
            let ripple = 0.5 + 0.5 * sin(Double(index) * 0.9)
            return max(3, CGFloat(envelope * (0.18 + 0.34 * ripple)) * total)
        }
        let normalized = min(1, Double(level) * 6)
        return max(4, CGFloat(envelope * normalized) * total)
    }
}

// MARK: - Permission page

/// A permission step (microphone / accessibility / notifications): an icon tile,
/// heading + live status line, body copy, and a primary action with an optional
/// secondary (e.g. "Skip for now").
struct OnboardingPermissionPage: View {
    let kicker: String
    let icon: String
    let heading: String
    let bodyText: String
    let granted: Bool
    let denied: Bool
    let working: Bool
    let primaryLabel: String
    let primaryAction: () -> Void
    var secondaryLabel: String?
    var secondaryAction: (() -> Void)?

    private var statusLine: String {
        if granted { return "Granted. You're good to go." }
        if denied { return "Turned off — open Settings to allow it." }
        return "Not yet granted."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(granted ? AnyShapeStyle(Theme.success.opacity(0.18)) : AnyShapeStyle(Theme.accentSoft))
                        .frame(width: 56, height: 56)
                    Image(systemName: granted ? "checkmark" : icon)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(granted ? Theme.success : Theme.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    KickerLabel(kicker)
                    Text(heading)
                        .font(Typography.sans(23, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(statusLine)
                        .font(Typography.body)
                        .foregroundStyle(granted ? Theme.success : Theme.textSecondary)
                }
                Spacer()
            }

            Text(bodyText)
                .font(Typography.sans(15))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            HStack(spacing: 12) {
                if granted {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Granted").font(Typography.headline).tracking(Typography.headlineTracking)
                    }
                    .foregroundStyle(Theme.success)
                } else if working {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                        Text("Waiting for your response…")
                            .font(Typography.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    PrimaryButton(title: primaryLabel, action: primaryAction)
                    if let secondaryLabel, let secondaryAction {
                        SecondaryButton(title: secondaryLabel, action: secondaryAction)
                    }
                }
                Spacer()
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Welcome bullet

/// A single accent-bulleted line on the welcome page.
struct OnboardingBullet: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
            Text(text)
                .font(Typography.sans(15))
                .foregroundStyle(Theme.textPrimary.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
