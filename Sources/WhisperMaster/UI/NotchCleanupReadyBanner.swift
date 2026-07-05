import SwiftUI

/// Shown once in the notch when the optional on-device "smart cleanup" model
/// finishes downloading + warming, so the user knows the feature they opted into
/// is now live. This is the **only** notch signal for the model — its download
/// progress lives solely in Settings. White-on-black, two short lines,
/// non-interactive: it drops for a moment and retracts.
struct NotchCleanupReadyBanner: View {
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            VStack(alignment: .leading, spacing: 1) {
                Text("Smart cleanup is ready")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)

                Text("It'll tidy up your dictation from now on")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }
}
