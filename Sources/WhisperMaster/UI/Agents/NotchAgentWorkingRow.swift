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
    /// The socket's view of this turn, when the owner has one.
    var live: String?
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
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Notch.textSecondary)
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

    private var caption: String { Self.caption(for: session, now: now, live: live) }

    /// One line, like the dictation row's state word: what it is doing (or which
    /// codebase), then how long. Never the raw tool name — a notch reading
    /// `mcp__foo__bar` is the same leak the approval card's raw arguments were.
    ///
    /// Static because `DictationPillContent` feeds the same string to
    /// `wideWing(forStateLabel:)`: the wing is sized to the caption, so the two
    /// must be one computation or the bar truncates exactly the words it grew for.
    /// `live` is the socket's own view of this turn (`AgentTurnLog.currentActivity`)
    /// and wins over the polled session. The poll reports a session's *last known*
    /// activity, so between sending a new prompt and its first tool call it still
    /// names the previous turn's command — which reads as a caption that never
    /// changes whatever you say.
    static func caption(for session: AgentSession, now: Date, live: String? = nil) -> String {
        // **No fallback to the polled activity.** This row only ever shows the
        // session the socket is attached to, so the socket is the authority — and
        // the poll carries a session's *last known* activity, which for a turn that
        // has not called anything yet is the previous turn's command. Naming the
        // repo is the honest answer to "what is it doing"; naming a command it is
        // not running is not. (`session.activity` still serves the glance, which
        // lists sessions nothing is attached to.)
        let subject = trimmedSubject(
            (live?.isEmpty == false ? live : nil) ?? session.repo)
        // The row shows from the send onward, which is before kunai reports the
        // turn as running — in that beat "Idle" would be a lie about words that
        // are mid-flight, so the pending state reads as what it is.
        let status = session.state == .running
            ? session.statusLabel(now: now) : "Starting"
        return "\(subject) · \(status)"
    }

    /// The bar's wing is capped, so an over-long caption truncates — and with the
    /// subject leading, what got cut was the elapsed time at the end rather than the
    /// middle of a shell command. Trimming the subject to a budget keeps the status
    /// on screen, which is the half that changes.
    static func trimmedSubject(_ subject: String) -> String {
        let compact = AgentTurnLog.trimmedCommand(subject)
        guard compact.count > maxSubjectCharacters else { return compact }
        let cut = compact.prefix(maxSubjectCharacters)
            .reversed().drop(while: { !$0.isWhitespace }).reversed()
        let kept = String(cut).trimmingCharacters(in: .whitespaces)
        return (kept.isEmpty ? String(compact.prefix(maxSubjectCharacters)) : kept) + "…"
    }

    /// Measured against `NotchSurfaceLayout.maxStateLabelWing`: past this the whole
    /// caption stops fitting the wing and the status is what gets dropped.
    static let maxSubjectCharacters = 34
}
