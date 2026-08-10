import SwiftUI

/// An agent mid-turn, as a slim row rather than a panel.
///
/// This is the state the surface spends most of its time in, and it exists because
/// the full session tail is the wrong shape for it: a turn runs for minutes, and a
/// 200pt band sitting over the menu bar for minutes is not ambient awareness, it is
/// an obstruction. So a running turn gets the **row** — the same two-ended shape
/// dictation uses, the caption at the leading edge and the orb at the trailing one —
/// and the tail comes back once there is something finished to read.
///
/// The orb is `.working`, never `.listening`: ember means *your voice*, and nothing
/// here is hearing you.
struct NotchAgentWorkingRow: View {
    let session: AgentSession
    let now: Date
    /// Matches the row form the dictation bar uses on this geometry, so the two read
    /// as the same surface in two moods.
    var orbSize: CGFloat = NotchTranscriptRow.orbDiameter
    var verticalInset: CGFloat = NotchTranscriptRow.verticalPadding
    var labelMaxWidth: CGFloat?

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text(caption)
                    .font(Typography.notchBody)
                    .foregroundStyle(Theme.Notch.text)
                Text(session.statusLabel(now: now))
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.textSecondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: labelMaxWidth, alignment: .leading)

            Spacer(minLength: Theme.Space.sm)

            OrbView(level: 0, mode: .working, diameter: orbSize, preset: .small)
                .frame(width: orbSize, height: orbSize)
        }
        .padding(.horizontal, NotchTranscriptRow.horizontalPadding)
        .padding(.vertical, verticalInset)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption). \(session.statusLabel(now: now))")
    }

    /// What it is doing, or which codebase it is doing it in. Never the raw tool
    /// name — a notch reading `mcp__foo__bar` is the same leak the approval card's
    /// raw arguments were.
    private var caption: String {
        guard let activity = session.activity, !activity.isEmpty else { return session.repo }
        return activity
    }
}
