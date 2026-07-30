import SwiftUI

/// The "what's my day" answer, shown in the notch after a day query. Two lines
/// (headline + next-thing) via the shared `NotchBannerRow`, on the dark surface.
struct NotchDaySummaryBanner: View {
    let summary: DaySummary

    var body: some View {
        NotchBannerRow(
            icon: "calendar",
            title: summary.headline,
            accessibilityText: summary.accessibilityText,
            subtitle: { Text(subtitleText) }
        )
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
}
