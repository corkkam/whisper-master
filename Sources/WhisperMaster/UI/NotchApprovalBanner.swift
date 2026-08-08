import SwiftUI

/// The consent card for one write, in the notch.
///
/// Three choices, not two: **Once**, **Always**, **No**. "Always" is what makes the
/// feature usable day-to-day, and it's also the one that creates a standing grant, so
/// the card names exactly what that grant will cover — the tool, the target, and the
/// connection. Approving "post to #standup" must never read as approving Slack in
/// general.
///
/// Interactive, so it's in `DictationPillContent.allowsHitTesting` and the
/// `setInteractive` call in the AppDelegate refresh loop, alongside the Bluetooth and
/// undelivered banners.
struct NotchApprovalBanner: View {
    let approval: PendingApproval
    let onResolve: (ApprovalOutcome) -> Void

    var body: some View {
        NotchBannerRow(
            icon: "hand.raised",
            title: approval.headline,
            accessibilityText: accessibilityText,
            // The payload is user-authored and unbounded (a dictated message body
            // has no length limit), so it gives way to the three buttons rather
            // than pushing them off the band — an approval card whose answers are
            // off-screen can only be answered by walking away from it.
            textGivesWayToTrailing: true,
            subtitle: { Text(approval.detail) },
            trailing: {
                HStack(spacing: 6) {
                    choice("Once", .allowedOnce)
                    choice("Always", .allowedAlways)
                    choice("No", .denied, isDestructive: true)
                }
            })
    }

    /// VoiceOver gets the full payload untruncated — a screen-reader user must not be
    /// asked to consent to something the visual layout abbreviated away.
    private var accessibilityText: String {
        "\(approval.headline). \(approval.detail). Choose once, always, or no."
    }

    private func choice(_ title: String,
                        _ outcome: ApprovalOutcome,
                        isDestructive: Bool = false) -> some View {
        Button(title) { onResolve(outcome) }
            .buttonStyle(.plain)
            .font(Typography.notchCaption)
            .foregroundStyle(isDestructive ? Theme.Notch.danger : Theme.Notch.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Theme.Notch.text.opacity(outcome == .allowedAlways ? 0.22 : 0.12)))
            .accessibilityLabel(accessibilityLabel(for: outcome))
            .pointerCursor()
    }

    private func accessibilityLabel(for outcome: ApprovalOutcome) -> String {
        switch outcome {
        case .allowedOnce: return "Allow once"
        case .allowedAlways:
            return "Always allow \(approval.tool) to \(approval.target) on \(approval.instanceLabel)"
        case .denied: return "Don't allow"
        }
    }
}
