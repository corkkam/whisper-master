import SwiftUI

/// The "what's my day" answer, shown in the notch after a day query. Two lines
/// (headline + next-thing) via the shared `NotchBannerRow`, on the dark surface.
struct NotchDaySummaryBanner: View {
    let summary: DaySummary
    /// Being read aloud right now. The glyph says so — otherwise a voice comes out of
    /// the Mac with nothing on screen indicating which of its surfaces is talking.
    var isSpeaking: Bool = false

    var body: some View {
        NotchBannerRow(
            icon: isSpeaking ? "speaker.wave.2.fill" : "calendar",
            title: summary.headline,
            accessibilityText: accessibilityText,
            subtitle: { Text(subtitleText) }
        )
        // Crossfade rather than a hard swap, and no perpetual motion: the record dot's
        // breathe is the system's only recurring animation, and a pulsing notch would
        // spend that meaning twice (see the design rules in `UI/CLAUDE.md`).
        .contentTransition(.symbolEffect(.replace))
    }

    /// The next-thing line, with a quiet tail when an enabled connector couldn't
    /// contribute — so a gap is never silently hidden — and a "just this one" note
    /// when the question named a single connector.
    private var subtitleText: String {
        var line = summary.detail
        if let scopedTo = summary.scopedTo {
            line += "  ·  \(scopedTo) only"
        }
        if !summary.gaps.isEmpty {
            let names = summary.gaps.map(\.instanceLabel).joined(separator: ", ")
            line += "  ·  couldn't read \(names)"
        }
        return line
    }

    /// VoiceOver never hears the "reading aloud" state, because the speaker stands down
    /// entirely when VoiceOver is running (`AnswerSpeaker.speak`) — announcing a voice
    /// that isn't going to talk would just be wrong.
    private var accessibilityText: String { summary.accessibilityText }
}
