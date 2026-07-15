import SwiftUI

/// A gentle "you haven't used me in a while" line shown inside the notch.
///
/// A single short line on the dark notch surface, deliberately non-interactive —
/// it simply appears for a moment and retracts. The scheduler owns its lifetime;
/// this view is pure presentation. (It's the one banner with no icon/subtitle
/// split, so it uses the `Theme.Notch` tokens directly rather than
/// `NotchBannerRow`.)
struct NotchReminderBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.notchBody)
            .foregroundStyle(Theme.Notch.text.opacity(0.92))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Theme.Space.lg)
            .frame(maxWidth: .infinity)
            .accessibilityElement()
            .accessibilityLabel(text)
    }
}
