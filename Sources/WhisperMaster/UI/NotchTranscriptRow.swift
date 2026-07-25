import SwiftUI

/// The dictation line on the notch band: a leading glyph (the orb, or an icon
/// for a finished beat) and the words themselves, rolling by as the engine
/// emits them.
///
/// The band is only as wide as the notch plus its two wings, so the text is a
/// single line truncated from the **head** — the newest words stay pinned at the
/// right edge and older ones slide out of view, which is what you want to see
/// while you're still talking. Confirmed text renders at full strength and the
/// volatile tail a shade quieter, so you can tell what the engine has locked in
/// from what it may still revise.
///
/// With nothing transcribed yet the glyph centers itself in the band (a lone orb
/// hugging the left edge of a wide band reads as broken); it slides to the left
/// as soon as the first words arrive.
struct NotchTranscriptRow: View {
    /// Text the engine has locked in — full-strength ink.
    var confirmed: String = ""
    /// The volatile tail it may still revise — rendered quieter. Empty once the
    /// transcript is final.
    var partial: String = ""
    /// Live mic level, driving the listening wave.
    var level: Float = 0
    /// Which orb figure to show. Ignored when `icon` is set.
    var mode: OrbView.Mode = .working
    /// An SF Symbol shown instead of the orb — used for the finished "polished"
    /// beat, where there is nothing left to animate.
    var icon: String?
    /// Spoken description of the whole row.
    var accessibilityLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isEmpty: Bool {
        confirmed.isEmpty && partial.isEmpty
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            glyph

            if !isEmpty {
                text
                    .font(Typography.notchBody)
                    .lineLimit(1)
                    // Head truncation keeps the *newest* words on screen.
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: isEmpty ? .center : .leading)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: isEmpty)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var glyph: some View {
        if let icon {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Notch.accent)
                .frame(width: 22, height: 22)
        } else {
            OrbView(level: level, mode: mode)
        }
    }

    /// One concatenated `Text` so the two runs flow as a single truncatable line
    /// (an `HStack` of two `Text`s would truncate each independently).
    private var text: Text {
        let locked = Text(confirmed)
            .foregroundColor(Theme.Notch.text)
        guard !partial.isEmpty else { return locked }
        let separator = confirmed.isEmpty ? "" : " "
        return locked + Text(separator + partial)
            .foregroundColor(Theme.Notch.textSecondary)
    }
}
