import SwiftUI

/// The surface you *open*, as opposed to the one that interrupts you.
///
/// A tap of the agent key opens it; a tap closes it; clicking a row makes that
/// session the one your next spoken prompt goes to.
///
/// It is a list of rows rather than cards, and it carries no header or legend — the
/// version that had both read as a dropdown menu pinned under the notch rather than
/// part of it. It is also **only a list**: an earlier version drilled into a dense
/// transcript with role labels and monospaced tool rows, which is a log file on the
/// bezel. What a finished turn has to say arrives as one banner line
/// (`NotchAgentReplyBanner`), the way every other band in this app reports itself.
struct NotchAgentGlance: View {
    let sessions: [AgentSession]
    /// The session a spoken prompt would go to, marked so the choice is visible
    /// before you hold the key rather than after you let go.
    let selectedID: String?
    let now: Date
    let onOpen: (AgentSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            if sessions.isEmpty {
                empty
            } else {
                ForEach(visible) { session in
                    row(session)
                        .frame(height: Metrics.row)
                }
                if hiddenCount > 0 {
                    Text("+\(hiddenCount) more in kunai")
                        .font(Typography.notchCaption)
                        .foregroundStyle(Theme.Notch.textTertiary)
                        .frame(height: Metrics.row)
                }
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var empty: some View {
        // An honest empty state rather than a blank band: the surface opened because
        // the user asked it to, so it owes them a sentence.
        VStack(alignment: .leading, spacing: 2) {
            Text("No sessions running")
                .font(Typography.notchTitle)
                .foregroundStyle(Theme.Notch.text)
            Text("Hold the key and talk to start one")
                .font(Typography.notchCaption)
                .foregroundStyle(Theme.Notch.textSecondary)
        }
        .frame(height: Metrics.row * 2)
    }

    private func row(_ session: AgentSession) -> some View {
        Button { onOpen(session) } label: {
            HStack(spacing: Theme.Space.sm) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(session.id == selectedID ? Theme.Notch.accent : Color.clear)
                    .frame(width: 3, height: 18)
                Circle()
                    .fill(dotColor(for: session))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.repo)
                        .font(Typography.notchTitle)
                        .foregroundStyle(Theme.Notch.text)
                    Text(session.subtitle)
                        .font(Typography.notchCaption)
                        .foregroundStyle(Theme.Notch.textSecondary)
                }
                .lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
                Text(session.statusLabel(now: now))
                    .font(Typography.notchCaption)
                    .foregroundStyle(
                        session.isWaiting ? Theme.Notch.warning : Theme.Notch.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(
            "\(session.repo), \(session.subtitle), \(session.statusLabel(now: now))")
    }

    private func dotColor(for session: AgentSession) -> Color {
        switch session.state {
        case .awaitingPermission: return Theme.Notch.warning
        case .running, .starting: return Theme.Notch.success
        case .idle: return Theme.Notch.textTertiary.opacity(0.6)
        }
    }

    // MARK: Metrics

    private var visible: [AgentSession] { Array(sessions.prefix(Metrics.maxRows)) }
    private var hiddenCount: Int { max(0, sessions.count - Metrics.maxRows) }

    /// Pinned, and read by `thickness` below, for the reason spelled out on
    /// `NotchAgentChoiceCard.Metrics`: the band is sized before this lays out.
    enum Metrics {
        static let row: CGFloat = 32
        static let rowSpacing: CGFloat = Theme.Space.xs
        static let verticalPadding: CGFloat = Theme.Space.md
        static let maxRows = 4
    }

    /// How tall the list form needs to be.
    static func listThickness(sessionCount: Int) -> CGFloat {
        let rows = sessionCount == 0 ? 2 : min(sessionCount, Metrics.maxRows)
        let extra = sessionCount > Metrics.maxRows ? 1 : 0
        let total = CGFloat(rows + extra)
        return Metrics.verticalPadding * 2 + total * Metrics.row
            + max(0, total - 1) * Metrics.rowSpacing
    }

    /// The tallest the glance can be, for `NotchSurfaceLayout`.
    static var maxThickness: CGFloat { listThickness(sessionCount: Metrics.maxRows + 1) }
}
