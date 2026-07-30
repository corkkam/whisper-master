import SwiftUI

/// The dictation bar: what the app is doing at the leading edge, the orb at the
/// trailing edge.
///
/// The two ends are fixed and never swap: the leading edge always carries the
/// state in words ("Dictating") and the orb always sits at the right, where
/// `NotchGlow`'s corner bloom lights the surface behind it.
///
/// The light is **not** this view's job — `NotchGlow`, applied to the whole surface
/// by `DictationPillContent`, owns it, so the hue follows `NotchActivity` and every
/// band state gets lit rather than only this one.
///
/// **The band does not stream the live transcript.** Reading your own words back
/// while speaking them pulls your eyes to the bezel and off whatever you're
/// dictating into, so the words land in the target app and the band reports the
/// *state* instead. `model` is therefore empty for the whole recording →
/// finalizing → polishing stretch, and non-empty only for the finished
/// **polished** beat, where holding the rewritten line for a moment is the point.
///
/// When there is text, it is a **three-line window**: each word fades in on its
/// own, lines fill top-to-bottom, and once the third is full the whole block
/// slides upward so the newest line is always the bottom one. Text that has
/// scrolled off is clipped away behind a soft fade at the top edge.
///
/// The line breaking is not `Text`'s — it comes from `NotchTranscriptModel`,
/// resolved by the owner (`DictationPillContent`) so the band's height and this
/// view agree on the line count without a measurement round-trip.
struct NotchTranscriptRow: View {
    /// Diameter of the orb on the band. Shared with `NotchSurfaceLayout`, which
    /// sizes the band around it.
    static let orbDiameter: CGFloat = 40
    /// Gap between the orb and the words.
    static let gutter: CGFloat = Theme.Space.md
    /// Inset from the surface's left and right edges.
    static let horizontalPadding: CGFloat = Theme.Space.xl
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
    /// Hue for `icon`. Comes from the band's `NotchActivity` so the glyph and the
    /// light in the surface can't say different things — a signal-lit machine state
    /// with an ember glyph claims the rewrite was you.
    var tint: Color = Theme.Notch.accent
    /// What the app is doing, in words, shown at the leading edge until the first
    /// word of the transcript lands.
    var label: String = ""
    /// Spoken description of the whole row.
    var accessibilityLabel: String
    /// Overrides for the notch-row layout, where the whole surface is only as tall
    /// as the menu bar. `nil` keeps the band metrics.
    ///
    /// The row can't fit the 40pt orb or 12pt insets the band is built around, so
    /// the owner passes the measurements that do fit; everything else — the two
    /// fixed ends, the fonts, the wrap — is identical, because it is the same bar,
    /// just drawn in the menu bar instead of under it.
    var orbSize: CGFloat?
    var verticalInset: CGFloat?

    private var resolvedOrbSize: CGFloat { orbSize ?? Self.orbDiameter }
    private var resolvedVerticalInset: CGFloat { verticalInset ?? Self.verticalPadding }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width available to the words, given the surface the band is drawn on. The
    /// owner calls this to resolve the model, so both sides wrap identically.
    ///
    /// `gutter` is charged **three times**, which is what `body`'s `HStack` really
    /// spends: one stack gap either side of the `Spacer`, plus the `Spacer`'s own
    /// `minLength`. Charging it once over-budgets the wrap by 24pt, and a line
    /// measured to fit a column it doesn't get makes `Text` truncate a whole word
    /// mid-line ("transc…") — invisible while the bar was wide enough that nothing
    /// wrapped, immediate once it isn't.
    static func textWidth(surfaceWidth: CGFloat) -> CGFloat {
        max(40, surfaceWidth - horizontalPadding * 2 - orbDiameter - gutter * 3)
    }

    var body: some View {
        HStack(spacing: Self.gutter) {
            leading
            Spacer(minLength: Self.gutter)
            glyph
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, resolvedVerticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The words if there are any, otherwise the state in words.
    @ViewBuilder
    private var leading: some View {
        if model.isEmpty {
            Text(label)
                .font(Typography.notchLabel)
                .foregroundStyle(Theme.Notch.text)
                .lineLimit(1)
        } else {
            transcript
        }
    }

    @ViewBuilder
    private var glyph: some View {
        if let icon {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: resolvedOrbSize, height: resolvedOrbSize)
        } else {
            OrbView(level: level, mode: mode, diameter: resolvedOrbSize)
        }
    }

    /// The three-line window. Every line is laid out, then the stack is shifted
    /// up by the ones that have scrolled off and clipped to the window — so older
    /// text slides out of the top as new lines arrive, which is the whole point.
    private var transcript: some View {
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
