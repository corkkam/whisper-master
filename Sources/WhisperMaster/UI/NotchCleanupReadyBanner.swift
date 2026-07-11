import SwiftUI

/// Shown once in the notch when the optional on-device "smart cleanup" model
/// finishes downloading + warming, so the user knows the feature they opted into
/// is now live. This is the **only** notch signal for the model — its download
/// progress lives solely in Settings. On the dark notch surface, two short lines,
/// non-interactive: it drops for a moment and retracts.
struct NotchCleanupReadyBanner: View {
    var body: some View {
        NotchBannerRow(
            icon: "wand.and.stars",
            title: "Smart cleanup is ready",
            subtitle: "It'll tidy up your dictation from now on"
        )
    }
}
