import SwiftUI

/// The progress dots + connectors shown across the top of the onboarding wizard.
struct OnboardingStepHeader: View {
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { value in
                dot(for: value)
                if value != OnboardingStep.allCases.last {
                    Rectangle()
                        .fill(value.rawValue < step.rawValue ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.stroke))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func dot(for value: OnboardingStep) -> some View {
        let isCurrent = value == step
        let isComplete = value.rawValue < step.rawValue
        return ZStack {
            Circle()
                .fill(isCurrent || isComplete ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface))
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().strokeBorder(isCurrent ? Color.white.opacity(0.3) : Theme.strokeStrong, lineWidth: 1)
                )
            if isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
            } else if isCurrent {
                Circle().fill(.white).frame(width: 6, height: 6)
            }
        }
    }
}

/// A permission step page (microphone / accessibility): icon, heading, body, and
/// a primary action with an optional secondary (e.g. "Skip for now").
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
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(granted ? "Granted. You're good to go." : "Not yet granted.")
                        .font(Typography.body)
                        .foregroundStyle(granted ? Theme.success : Theme.textSecondary)
                }
                Spacer()
            }

            Text(bodyText)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            HStack(spacing: 12) {
                if granted {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Granted").font(Typography.headline)
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

/// The center-weighted bar meter used for the live mic check.
struct OnboardingLevelMeter: View {
    let level: Float
    let active: Bool

    private let barCount = 32

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 4
            let totalSpacing = spacing * CGFloat(barCount - 1)
            let barWidth = max(2, (geo.size.width - totalSpacing) / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    bar(index: index, width: barWidth, height: geo.size.height)
                }
            }
        }
    }

    private func bar(index: Int, width: CGFloat, height: CGFloat) -> some View {
        let center = Double(barCount - 1) / 2.0
        let distance = abs(Double(index) - center) / center
        let envelope = 1.0 - pow(distance, 2.0)
        let normalized = min(1.0, Double(level) * 6.0)
        let h = max(4, CGFloat(envelope * normalized) * height)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(active ? Theme.accent : Theme.strokeStrong)
            .frame(width: width, height: h)
            .animation(.easeOut(duration: 0.08), value: level)
    }
}

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
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
