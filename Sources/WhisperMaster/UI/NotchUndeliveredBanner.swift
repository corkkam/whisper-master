import SwiftUI

/// Shown in the notch when a finished dictation had no focused text field to
/// paste into. The transcript is already safe in history and on the clipboard;
/// this shows the words themselves so you can see nothing was lost, and gives a
/// **Copy** button as an explicit way to get them — the ⌘V hint alone assumes
/// the clipboard survived, and a stray copy in between would have eaten it.
///
/// When the on-device polish rewrites the transcript after the fact, `text` is
/// the polished version, so both the preview and the button follow the better
/// wording.
///
/// Unlike the other hints this banner is **interactive**, so the pill panel takes
/// clicks while it's up (`DictationPillWindow.setInteractive`).
struct NotchUndeliveredBanner: View {
    /// The transcript to show and copy. Empty falls back to the plain hint.
    var text: String = ""
    /// Puts `text` on the clipboard. Injected so the view stays free of AppKit.
    var onCopy: () -> Void = {}

    /// Flips the button to a confirmation once tapped. Local to the banner —
    /// it retracts on its own, so there's nothing to persist.
    @State private var copied = false

    private var accessibilityText: String {
        text.isEmpty
            ? "Nowhere to type that. Copied to clipboard, press Command V to paste."
            : "Nowhere to type that. \(text)"
    }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "text.insert")
                .font(Typography.notchTitle)
                .foregroundStyle(Theme.Notch.text.opacity(0.9))

            VStack(alignment: .leading, spacing: 1) {
                Text("Nowhere to type that")
                    .font(Typography.notchTitle)
                    .foregroundStyle(Theme.Notch.text)

                subtitle
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)

            copyButton
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(maxWidth: .infinity)
        // The banner's view identity outlives a single dictation; a later
        // undelivered transcript must not inherit the previous "Copied".
        .onChange(of: text) { copied = false }
    }

    /// The transcript itself when we have it (tail-truncated — the opening words
    /// are what identify it), otherwise the ⌘V hint.
    @ViewBuilder
    private var subtitle: some View {
        if text.isEmpty {
            HStack(spacing: Theme.Space.xs) {
                Text("Copied to clipboard. Press")
                KeyHint("⌘V")
                Text("to paste")
            }
        } else {
            Text(text)
        }
    }

    private var copyButton: some View {
        Button(action: copy) {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .font(Typography.notchTitle)
                .foregroundStyle(Theme.Notch.surface)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.Notch.text))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(copied)
    }

    private func copy() {
        onCopy()
        copied = true
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
