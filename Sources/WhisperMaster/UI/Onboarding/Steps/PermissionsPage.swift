import SwiftUI

/// Combined Microphone + Accessibility grants on one page so first-run is a
/// single allow step instead of two separate wizard pages.
struct PermissionsPage: View {
    let micGranted: Bool
    let micDenied: Bool
    let requestingMic: Bool
    let accessibilityGranted: Bool
    let onGrantMicrophone: () -> Void
    let onGrantAccessibility: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                KickerLabel("Get set up")
                Text("Allow two things")
                    .font(Typography.sans(23, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Microphone is required. Accessibility drops words at your cursor — skip it and we'll put the text on your clipboard instead. The voice engine downloads in the background if it isn't already on this Mac.")
                    .font(Typography.sans(15))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }

            VStack(spacing: 12) {
                permissionCard(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: "Listens only while you hold the record key. Everything stays on this Mac.",
                    granted: micGranted,
                    denied: micDenied,
                    working: requestingMic,
                    primaryLabel: micDenied ? "Open System Settings" : "Allow Microphone",
                    action: onGrantMicrophone
                )

                permissionCard(
                    icon: "keyboard",
                    title: "Accessibility",
                    subtitle: "Types the transcript into whatever app you're in.",
                    granted: accessibilityGranted,
                    denied: false,
                    working: false,
                    primaryLabel: "Allow Accessibility",
                    action: onGrantAccessibility
                )
            }

            Spacer(minLength: 0)
        }
    }

    private func permissionCard(
        icon: String,
        title: String,
        subtitle: String,
        granted: Bool,
        denied: Bool,
        working: Bool,
        primaryLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(granted ? AnyShapeStyle(Theme.success.opacity(0.18)) : AnyShapeStyle(Theme.accentSoft))
                    .frame(width: 46, height: 46)
                Image(systemName: granted ? "checkmark" : icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(granted ? Theme.success : Theme.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusLine(granted: granted, denied: denied))
                    .font(Typography.caption)
                    .foregroundStyle(granted ? Theme.success : Theme.textTertiary)
            }

            Spacer(minLength: 8)

            trailingControl(
                granted: granted,
                working: working,
                primaryLabel: primaryLabel,
                action: action
            )
        }
        .padding(16)
        .onboardingCard(highlighted: granted)
    }

    private func statusLine(granted: Bool, denied: Bool) -> String {
        if granted { return "Granted" }
        if denied { return "Turned off — open Settings to allow it." }
        return "Not yet granted"
    }

    @ViewBuilder
    private func trailingControl(
        granted: Bool,
        working: Bool,
        primaryLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        if granted {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.success)
                .accessibilityLabel("Granted")
        } else if working {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
        } else {
            PrimaryButton(title: primaryLabel, action: action)
        }
    }
}
