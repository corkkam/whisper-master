import SwiftUI

/// Shown in the notch when a finished dictation had no focused text field to
/// paste into. The transcript is already safe in history; this tells the user
/// where it went and how to get it back. On the dark notch surface, single line,
/// and deliberately non-interactive — it appears for a moment and retracts, so
/// the pill stays click-through.
struct NotchUndeliveredBanner: View {
    var body: some View {
        NotchBannerRow(
            icon: "text.insert",
            title: "Nowhere to type that",
            accessibilityText: "Nowhere to type that. Copied to clipboard, press Command V to paste."
        ) {
            HStack(spacing: Theme.Space.xs) {
                Text("Copied to clipboard. Press")
                KeyHint("⌘V")
                Text("to paste")
            }
        }
    }
}

/// A small keycap-styled inline hint (e.g. "⇧⌘V") for use inside the banner.
private struct KeyHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.Notch.text.opacity(0.85))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.Notch.hairline)
            )
    }
}
