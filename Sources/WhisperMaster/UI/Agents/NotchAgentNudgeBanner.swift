import SwiftUI

/// A session that is **not** on screen has done something worth knowing: it stopped
/// on a permission, or it finished.
///
/// The smallest surface this feature could have. It is deliberately **not** the other
/// session's card — we hold one socket, so we do not have that session's question,
/// and rendering a guess at it would be worse than saying nothing. It is a pointer:
/// which agent, what happened, and that a tap will take you there.
///
/// One line, one glyph, the same `NotchBannerRow` every other hint uses. A second
/// visual language for "another agent needs you" would make the band feel like a
/// notification centre, which is the one thing this whole surface is not.
struct NotchAgentNudgeBanner: View {
    let event: AgentAttention.Event

    var body: some View {
        NotchBannerRow(
            icon: icon,
            title: event.line,
            accessibilityText: "\(event.line). \(event.hint).",
            subtitle: { Text(event.hint) },
            trailing: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Notch.textTertiary)
            })
    }

    /// A blocked agent wears the same glyph the approval card does, because it is the
    /// same situation seen from further away. A finished one wears the reply's.
    private var icon: String {
        switch event.kind {
        case .needsYou: return "hand.raised.fill"
        case .finished: return "sparkles"
        }
    }
}
