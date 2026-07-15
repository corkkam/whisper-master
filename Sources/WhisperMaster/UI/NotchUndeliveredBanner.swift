import SwiftUI

/// Shown in the notch when a finished dictation had no focused text field to
/// paste into. The transcript is already safe in history; this tells the user
/// where it went and how to get it back. White-on-black to sit on the notch
/// surface, single line, and deliberately non-interactive — it appears for a
/// moment and retracts, so the pill stays click-through.
struct NotchUndeliveredBanner: View {
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "text.insert")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            VStack(alignment: .leading, spacing: 1) {
                Text("Nowhere to type that")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 4) {
                    Text("Copied to clipboard. Press")
                    KeyHint("⌘V")
                    Text("to paste")
                }
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

/// A small keycap-styled inline hint (e.g. "⇧⌘V") for use inside the banner.
private struct KeyHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.14))
            )
    }
}
