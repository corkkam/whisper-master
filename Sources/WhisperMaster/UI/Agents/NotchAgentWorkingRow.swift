import SwiftUI

/// An agent mid-turn, in the menu-bar row — the same resting form a dictation
/// takes, because it is the same situation: something is running, nothing needs
/// reading, and the surface's job is to say so without taking any room.
///
/// One line at the leading edge, the working orb at the trailing edge, at
/// menu-bar height. **Not** a band: the first version dropped a slab below the
/// bezel with a two-line caption inside it and the orb adrift in empty black,
/// which is a shape nothing else in this app uses for "busy".
///
/// The orb is `.working`, never `.listening`: ember means *your voice*, and
/// nothing here is hearing you.
struct NotchAgentWorkingRow: View {
    let session: AgentSession
    let now: Date
    /// Matches the row form the dictation bar uses on this geometry, so the two
    /// read as the same surface in two moods.
    var orbSize: CGFloat = NotchTranscriptRow.orbDiameter
    var verticalInset: CGFloat = NotchTranscriptRow.verticalPadding
    var labelMaxWidth: CGFloat?
    /// Stop the turn — kunai's interrupt. On the row because the moment you want an
    /// agent to stop is the moment you are watching it work.
    var onStop: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Text(caption)
                .font(Typography.notchBody)
                .foregroundStyle(Theme.Notch.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: labelMaxWidth, alignment: .leading)

            Spacer(minLength: Theme.Space.sm)

            if let onStop {
                Button(action: onStop) {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Notch.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel("Stop this turn")
            }

            OrbView(level: 0, mode: .working, diameter: orbSize, preset: .small)
                .frame(width: orbSize, height: orbSize)
        }
        .padding(.horizontal, NotchTranscriptRow.horizontalPadding)
        .padding(.vertical, verticalInset)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(caption)
    }

    private var caption: String { Self.caption(for: session, now: now) }

    /// One line, like the dictation row's state word: what it is doing (or which
    /// codebase), then how long. Never the raw tool name — a notch reading
    /// `mcp__foo__bar` is the same leak the approval card's raw arguments were.
    ///
    /// Static because `DictationPillContent` feeds the same string to
    /// `wideWing(forStateLabel:)`: the wing is sized to the caption, so the two
    /// must be one computation or the bar truncates exactly the words it grew for.
    static func caption(for session: AgentSession, now: Date) -> String {
        let subject: String
        if let activity = session.activity, !activity.isEmpty {
            subject = activity
        } else {
            subject = session.repo
        }
        return "\(subject) · \(session.statusLabel(now: now))"
    }
}
