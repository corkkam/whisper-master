import SwiftUI

/// The dictation line on the notch band: a leading glyph (the orb, or an icon
/// for a finished beat) and the transcript itself, rolling by as the engine emits
/// it.
///
/// The orb is always the leading element — it never moves. Beside it is a
/// **three-line window** onto the transcript: each word fades in on its own as it
/// lands, lines fill top-to-bottom, and once the third is full the whole block
/// slides upward so the newest line is always the bottom one. Text that has
/// scrolled off is clipped away behind a soft fade at the top edge.
///
/// The line breaking is not `Text`'s — it comes from `NotchTranscriptModel`,
/// resolved by the owner (`DictationPillContent`) so the band's height and this
/// view agree on the line count without a measurement round-trip. Confirmed text
/// renders at full strength and the volatile tail a shade quieter, so you can
/// tell what the engine has locked in from what it may still revise.
struct NotchTranscriptRow: View {
    /// Diameter of the orb on the band. Shared with `NotchSurfaceLayout`, which
    /// sizes the band around it.
    static let orbDiameter: CGFloat = 40
    /// Gap between the orb and the words.
    static let gutter: CGFloat = Theme.Space.md
    /// Inset from the surface's left and right edges.
    static let horizontalPadding: CGFloat = Theme.Space.lg
    /// Inset above and below the content. `NotchSurfaceLayout` sizes the band
    /// around this, so the two can't drift apart.
    static let verticalPadding: CGFloat = Theme.Space.md

    /// The words and their line breaks, already resolved for the current width.
    var model: NotchTranscriptModel = NotchTranscriptModel()
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

    /// Width available to the words, given the surface the band is drawn on. The
    /// owner calls this to resolve the model, so both sides wrap identically.
    static func textWidth(surfaceWidth: CGFloat) -> CGFloat {
        max(40, surfaceWidth - horizontalPadding * 2 - orbDiameter - gutter)
    }

    var body: some View {
        HStack(spacing: Self.gutter) {
            glyph
            transcript
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var glyph: some View {
        if let icon {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Notch.accent)
                .frame(width: Self.orbDiameter, height: Self.orbDiameter)
        } else {
            OrbView(level: level, mode: mode, diameter: Self.orbDiameter)
        }
    }

    /// The three-line window. Every line is laid out, then the stack is shifted
    /// up by the ones that have scrolled off and clipped to the window — so older
    /// text slides out of the top as new lines arrive, which is the whole point.
    @ViewBuilder
    private var transcript: some View {
        if model.isEmpty {
            // Nothing transcribed yet: the orb carries the band on its own.
            Color.clear.frame(width: 0, height: 0)
        } else {
            VStack(alignment: .leading, spacing: NotchTextMetrics.lineSpacing) {
                ForEach(model.lines.indices, id: \.self) { index in
                    line(model.lines[index])
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .offset(y: -CGFloat(model.firstVisibleLine) * NotchTextMetrics.lineAdvance)
            .frame(height: NotchTextMetrics.blockHeight(lines: model.visibleLineCount), alignment: .top)
            .clipped()
            .mask(topFade)
            .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.quick), value: model)
        }
    }

    /// One wrapped line. Words are separate views so each can animate in by
    /// itself; the spacing is the measured space advance, so the line breaks land
    /// exactly where `NotchTranscriptModel` said they would.
    private func line(_ range: Range<Int>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NotchTextMetrics.spaceWidth) {
            ForEach(range, id: \.self) { index in
                Text(model.words[index].text)
                    .foregroundStyle(model.words[index].isPartial ? Theme.Notch.textSecondary : Theme.Notch.text)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
        .font(Typography.notchBody)
        .lineLimit(1)
        .frame(height: NotchTextMetrics.lineHeight, alignment: .leading)
    }

    /// Softens the top edge only once something has actually scrolled past it —
    /// an always-on fade would dim the first line of a one-line transcript.
    private var topFade: LinearGradient {
        LinearGradient(
            stops: model.hasScrolled
                ? [.init(color: Color.black.opacity(0.25), location: 0),
                   .init(color: .black, location: 0.28),
                   .init(color: .black, location: 1)]
                : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
