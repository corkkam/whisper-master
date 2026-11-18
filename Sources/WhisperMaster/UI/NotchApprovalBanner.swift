import SwiftUI

/// The consent card for one write, in the notch.
///
/// Three choices, not two: **Once**, **Always**, **No**. "Always" is what makes the
/// feature usable day-to-day, and it's also the one that creates a standing grant, so
/// the card names exactly what that grant will cover — the tool, the target, and the
/// connection. Approving "post to #standup" must never read as approving Slack in
/// general.
///
/// A run that has read connector text gets two choices, Once and No
/// (`PendingApproval.grantOffered`). The target may come from text other people
/// wrote, so the card does not offer a grant that would outlast it. That card also
/// carries one more line under the headline (`PendingApproval.readWarning`): the
/// model still proposes writes built from what it read, and with the card the only
/// gate, approving by habit is the risk. The extra line is why the band's height
/// is `thickness(for:banner:)` and not a constant.
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
            subtitle: {
                // Stacked, so the warning never takes width from the payload.
                VStack(alignment: .leading, spacing: 1) {
                    if let warning = approval.readWarning {
                        Text(warning).foregroundStyle(Theme.Notch.warning)
                    }
                    Text(approval.detail)
                }
            },
            trailing: {
                HStack(spacing: 6) {
                    choice("Once", .allowedOnce)
                    if approval.grantOffered { choice("Always", .allowedAlways) }
                    choice("No", .denied, isDestructive: true)
                }
            })
    }

    /// Height the warning line adds: one `notchCaption` line (10.5pt, ~12.5pt tall)
    /// plus the 1pt stack gap, rounded up. The band's height is decided before the
    /// card lays out, so this is pinned rather than measured.
    static let warningLineHeight: CGFloat = 14

    /// How tall the band must be for this card. `DictationPillContent.bandThickness`
    /// reads it, and `NotchSurfaceLayout.maxBandThickness` adds `warningLineHeight`
    /// to the banner: a band taller than its panel is clipped by its own window.
    static func thickness(for approval: PendingApproval, banner: CGFloat) -> CGFloat {
        approval.readWarning == nil ? banner : banner + warningLineHeight
    }

    /// VoiceOver gets the full payload untruncated — a screen-reader user must not be
    /// asked to consent to something the visual layout abbreviated away.
    var accessibilityText: String {
        let choices = approval.grantOffered ? "once, always, or no" : "once or no"
        let warning = approval.readWarning.map { " \($0)" } ?? ""
        return "\(approval.headline).\(warning) \(approval.detail). Choose \(choices)."
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

    /// `.timedOut` is not on the card — it is what happens when nobody touches it —
    /// so it has no button and no label of its own.
    private func accessibilityLabel(for outcome: ApprovalOutcome) -> String {
        switch outcome {
        case .allowedOnce: return "Allow once"
        case .allowedAlways:
            return "Always allow \(approval.tool) to \(approval.target) on \(approval.instanceLabel)"
        case .denied, .timedOut: return "Don't allow"
        }
    }
}
