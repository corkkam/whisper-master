import SwiftUI

/// What the agent said, once a turn is finished.
///
/// Deliberately the **same object as every other band in this app**: one icon, one
/// bold line, one quiet line, through `NotchBannerRow`. The first version of this
/// surface was a dense transcript — role labels in a left gutter, monospaced tool
/// rows, a footer — which is a log file pasted onto the bezel, not a notch band.
///
/// It follows the rule the notch already had for dictation: **the band reports state,
/// it does not stream a transcript.** The whole conversation lives in kunai; what
/// belongs here is the one line that says how the turn ended, exactly as the spoken
/// command confirmation does for a note or a reminder.
struct NotchAgentReplyBanner: View {
    let reply: String
    let repo: String
    /// How long the turn took, when kunai reported it.
    var duration: TimeInterval?

    var body: some View {
        NotchBannerRow(
            icon: "sparkles",
            title: reply,
            accessibilityText: "\(repo) replied. \(reply)",
            // The reply is model-written and therefore unbounded, so it truncates at
            // the tail rather than pushing the band past its own clip.
            textGivesWayToTrailing: true,
            subtitle: { Text(detail) },
            trailing: { EmptyView() })
    }

    private var detail: String {
        guard let duration, duration >= 1 else { return repo }
        return "\(repo) · \(Self.compact(duration))"
    }

    /// Seconds under a minute, then minutes. The band has no room for "3 minutes and
    /// 12 seconds" and nobody reads it there.
    static func compact(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        let remainder = whole % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }
}
