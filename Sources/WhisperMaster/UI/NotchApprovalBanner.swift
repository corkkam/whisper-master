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
            subtitle: { Text(payloadLine) },
            trailing: {
                HStack(spacing: 6) {
                    choice("Once", .allowedOnce)
                    choice("Always", .allowedAlways)
                    choice("No", .denied, isDestructive: true)
                }
            })
    }

    /// The payload, abbreviated to one line. The notch is one row, so a long message body
    /// is truncated — but the *target* is already in the headline, which is the part that
    /// decides whether this is the right thing to approve.
    private var payloadLine: String {
        let parts = approval.detailLines.map { "\($0.0): \($0.1)" }
        return parts.isEmpty ? "Approve this action?" : parts.joined(separator: "  ·  ")
    }

    /// VoiceOver gets the full payload untruncated — a screen-reader user must not be
    /// asked to consent to something the visual layout abbreviated away.
    private var accessibilityText: String {
        var parts = [approval.headline]
        parts += approval.detailLines.map { "\($0.0): \($0.1)" }
        parts.append("Choose once, always, or no.")
        return parts.joined(separator: ". ")
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
