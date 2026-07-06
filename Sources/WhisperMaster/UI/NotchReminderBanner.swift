import SwiftUI

/// A gentle "you haven't used me in a while" line shown inside the notch.
///
/// White-on-black to sit on the black notch surface, single short line, and
/// deliberately non-interactive — it simply appears for a moment and retracts.
/// The scheduler owns its lifetime; this view is pure presentation.
struct NotchReminderBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
    }
}
