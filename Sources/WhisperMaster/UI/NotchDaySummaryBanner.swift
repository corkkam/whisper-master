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

    /// The next-thing line, with a quiet "not connected" tail when a turned-on
    /// connector couldn't contribute — so a gap is never silently hidden.
    private var subtitleText: String {
        guard !summary.unavailable.isEmpty else { return summary.detail }
        return "\(summary.detail)  ·  connect \(summary.unavailable.joined(separator: ", "))"
    }
}
