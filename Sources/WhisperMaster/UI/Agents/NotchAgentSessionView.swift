import SwiftUI

/// One session, read on the bezel: the tail of the conversation and what it changed.
///
/// **This is not kunai.** It shows the last few turns, not the history — those files
/// run to tens of megabytes, which is why kunai tail-caps its own reads. The band
/// answers "what happened, and does it need me"; the browser answers "show me
/// everything", and the affordance to go there is part of the design rather than an
/// escape hatch.
struct NotchAgentSessionView: View {
    let session: AgentSession
    let log: AgentTurnLog
    let changes: AgentChangeSet
    let now: Date
    let onBack: () -> Void
    let onSelectMode: (KunaiWire.PermissionMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            header.frame(height: Metrics.header)
            Divider().overlay(Theme.Notch.hairline)
            ForEach(entries) { entry in
                line(entry).frame(height: Metrics.line)
            }
            if !changes.editedPaths.isEmpty {
                changed.frame(height: Metrics.line)
            }
            footer.frame(height: Metrics.footer)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Notch.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Back to sessions")

            Text(session.repo)
                .font(Typography.notchTitle)
                .foregroundStyle(Theme.Notch.text)
            Spacer(minLength: Theme.Space.sm)
            AgentModeControl(mode: session.mode, onSelect: onSelectMode)
            Text(session.statusLabel(now: now))
                .font(Typography.notchCaption)
                .foregroundStyle(
                    session.isWaiting ? Theme.Notch.warning : Theme.Notch.success)
        }
    }

    /// The newest entries, oldest first, capped so the band cannot grow without
    /// bound. Newest-last reads the way a conversation does.
    private var entries: [AgentTurnLog.Entry] {
        Array(log.renderable.suffix(Metrics.maxLines))
    }

    @ViewBuilder
    private func line(_ entry: AgentTurnLog.Entry) -> some View {
        switch entry {
        case .user(_, let text):
            labelled("YOU", Theme.Notch.textTertiary, text, Theme.Notch.text)
        case .assistant(_, let text):
            labelled("CLAUDE", Theme.Notch.success, text, Theme.Notch.text)
        case .tool(_, let name, let detail, let verdict):
            HStack(spacing: Theme.Space.sm) {
                Text(name.uppercased())
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.textTertiary)
                    .frame(width: Metrics.labelWidth, alignment: .leading)
                Text(detail.isEmpty ? name : detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.sm)
                if let verdict {
                    Text(verdict)
                        .font(Typography.notchCaption)
                        .foregroundStyle(Theme.Notch.textTertiary)
                }
            }
        }
    }

    private func labelled(
        _ label: String, _ labelTone: Color, _ text: String, _ tone: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(label)
                .font(Typography.notchCaption)
                .foregroundStyle(labelTone)
                .frame(width: Metrics.labelWidth, alignment: .leading)
            Text(text)
                .font(Typography.notchBody)
                .foregroundStyle(tone)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    /// What this turn edited. Short and readable, and deliberately **not** presented
    /// as what an undo would do: a revert is a whole-repository operation, so the
    /// blast radius is quoted from git only where the undo is actually offered.
    private var changed: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "pencil")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Notch.textTertiary)
                .frame(width: Metrics.labelWidth, alignment: .leading)
            Text(changes.editedPaths.joined(separator: "  ·  "))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.Notch.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.sm) {
            if let revert = changes.revert, !revert.isEmpty {
                // The irreversible half leads: restoring a tracked file is
                // recoverable, deleting an untracked one is not.
                Text("Undo would: \(revert.summary)")
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.textTertiary)
                    .lineLimit(1)
            } else {
                Text("Hold the key to reply")
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.textTertiary)
            }
            Spacer(minLength: Theme.Space.sm)
            Text("Open in kunai")
                .font(Typography.notchCaption)
                .foregroundStyle(Theme.Notch.textTertiary)
        }
    }

    // MARK: Metrics

    enum Metrics {
        static let header: CGFloat = 22
        static let line: CGFloat = 20
        static let footer: CGFloat = 16
        static let spacing: CGFloat = Theme.Space.xs
        static let verticalPadding: CGFloat = Theme.Space.md
        static let labelWidth: CGFloat = 48
        static let maxLines = 5
    }

    static func thickness(lineCount: Int, hasChanges: Bool) -> CGFloat {
        let lines = CGFloat(min(lineCount, Metrics.maxLines) + (hasChanges ? 1 : 0))
        // header + divider + lines + footer, with a gap between each pair.
        let children = lines + 3
        return Metrics.verticalPadding * 2 + Metrics.header + 1 + lines * Metrics.line
            + Metrics.footer + max(0, children - 1) * Metrics.spacing
    }

    static var maxThickness: CGFloat {
        thickness(lineCount: Metrics.maxLines, hasChanges: true)
    }
}
