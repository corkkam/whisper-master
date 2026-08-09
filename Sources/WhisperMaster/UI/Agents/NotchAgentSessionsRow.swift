import SwiftUI

/// The other sessions, as ambient context under whatever is asking.
///
/// Deliberately **not** a list of cards. The first version of this design gave three
/// equal rounded rows to three unequal things — one was a question and two were
/// status — and it read as a dropdown menu rather than a notch surface. Here the
/// question owns the panel and these are a dot, a name, and what each one is doing.
///
/// It shows at most `maxVisible` and then says how many it is not showing, because a
/// surface that silently drops rows reads as "that is all of them".
struct NotchAgentSessionsRow: View {
    let sessions: [AgentSession]
    let now: Date
    /// The mode control for the session currently asking, shown at the trailing edge
    /// so the way to stop being interrupted is next to the interruption.
    let mode: KunaiWire.PermissionMode?
    let onSelectMode: (KunaiWire.PermissionMode) -> Void

    static let maxVisible = 2

    private var visible: [AgentSession] { Array(sessions.prefix(Self.maxVisible)) }
    private var hiddenCount: Int { max(0, sessions.count - Self.maxVisible) }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.xl) {
            ForEach(visible) { session in
                entry(session)
            }
            if hiddenCount > 0 {
                Text("+\(hiddenCount) more")
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.textTertiary)
            }
            Spacer(minLength: Theme.Space.sm)
            if let mode {
                AgentModeControl(mode: mode, onSelect: onSelectMode)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func entry(_ session: AgentSession) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Circle()
                .fill(dotColor(for: session))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.repo)
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.text)
                Text(session.statusLabel(now: now))
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.textTertiary)
            }
            .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.repo), \(session.statusLabel(now: now))")
    }

    /// Hues follow the house rule: signal for a machine working, warning for
    /// something that wants a person, and a dead grey for idle. Ember is never used
    /// here — it means "your voice", and none of these rows is listening.
    private func dotColor(for session: AgentSession) -> Color {
        switch session.state {
        case .awaitingPermission: return Theme.Notch.warning
        case .running, .starting: return Theme.Notch.success
        case .idle: return Theme.Notch.textTertiary.opacity(0.6)
        }
    }
}
