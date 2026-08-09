import SwiftUI

/// A coding agent asking to run something, in the notch.
///
/// Deliberately the **same object** as `NotchApprovalBanner`: same three answers,
/// same capsule fills, same rule that Always names what the grant covers. A
/// permission from Claude Code is the same question a connector write already asks,
/// so it should not be a second, differently-shaped card the user has to learn.
///
/// The one difference is the second line. A connector approval names the connection;
/// this names the **codebase**, because that is what identifies the session when
/// three of them are running and only one is asking.
struct NotchAgentAskBanner: View {
    let approval: AgentApproval
    /// The repository the asking session is in.
    let repo: String
    let onResolve: (_ allow: Bool, _ always: Bool) -> Void

    var body: some View {
        NotchBannerRow(
            icon: "terminal",
            title: approval.headline,
            accessibilityText: accessibilityText,
            // The payload is a command or a path the model composed, so its length is
            // unbounded. It gives way to the answers rather than pushing them past
            // the band's clip, where they would be invisible and unclickable.
            textGivesWayToTrailing: true,
            subtitle: { Text(repo.isEmpty ? approval.detail : repo) },
            trailing: {
                HStack(spacing: 6) {
                    choice("Once", allow: true, always: false)
                    choice("Always", allow: true, always: true)
                    choice("No", allow: false, always: false, isDestructive: true)
                }
            })
    }

    /// VoiceOver gets the whole payload untruncated: a screen-reader user must not be
    /// asked to consent to something the layout abbreviated away.
    private var accessibilityText: String {
        "\(approval.headline). In \(repo). Choose once, always, or no."
    }

    private func choice(
        _ title: String, allow: Bool, always: Bool, isDestructive: Bool = false
    ) -> some View {
        Button(title) { onResolve(allow, always) }
            .buttonStyle(.plain)
            .font(Typography.notchCaption)
            .foregroundStyle(isDestructive ? Theme.Notch.danger : Theme.Notch.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.Notch.text.opacity(always ? 0.22 : 0.12)))
            .accessibilityLabel(label(allow: allow, always: always))
            .pointerCursor()
    }

    private func label(allow: Bool, always: Bool) -> String {
        guard allow else { return "Don't allow" }
        // Always creates a standing rule for this session, so the spoken label says
        // exactly what it covers rather than "always allow".
        return always
            ? "Always allow \(approval.tool) in \(repo) for this session"
            : "Allow once"
    }
}
