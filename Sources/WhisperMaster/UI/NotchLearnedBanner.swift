import SwiftUI

/// Shown briefly in the notch when the app auto-learns a corrected word into
/// the glossary ("Words to get right"), so that otherwise-silent addition is
/// visible. On the dark notch surface, two short lines, and non-interactive — it
/// appears for a moment and retracts, keeping the pill click-through.
struct NotchLearnedBanner: View {
    let term: String

    var body: some View {
        NotchBannerRow(
            icon: "sparkles",
            title: "Learned “\(term)”",
            subtitle: "Added to Words to get right"
        )
    }
}
