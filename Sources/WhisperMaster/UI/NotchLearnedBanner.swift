import SwiftUI

/// Shown briefly in the notch when the app auto-learns a corrected word into
/// the glossary ("Words to get right"), so that otherwise-silent addition is
/// visible. White-on-black to sit on the notch surface, two short lines, and
/// non-interactive — it appears for a moment and retracts, keeping the pill
/// click-through.
struct NotchLearnedBanner: View {
    let term: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            VStack(alignment: .leading, spacing: 1) {
                Text("Learned “\(term)”")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Added to Words to get right")
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
