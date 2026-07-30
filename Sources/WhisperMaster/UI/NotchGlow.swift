import SwiftUI

/// The light inside the notch band — the band's whole visual state language.
///
/// A matte black surface can only say one thing. Lighting its edges in the state's
/// own hue lets the band say what it is doing before you've read a word of it:
/// ember while it's listening to you, signal while the machine works, danger when
/// it failed. This is the notch equivalent of the accent-tinted glow the app uses
/// for elevation everywhere else (§4 — *"active state = accent-tinted shadow, not
/// a bright border"*), which is why it is a glow and not a coloured stroke.
///
/// **One light source, two layers.** The first attempt lit the trailing corner,
/// the bottom lip and *both* bottom corners independently; on a pure black band
/// that stacked into brown smudges with visible seams, and the leading-corner
/// bloom sat right under the words. So the light now comes from a single place —
/// the trailing corner, behind the orb, which is the one element that is actually
/// lit — and everything else is that source falling off:
///
///   1. **The bloom** — an elliptical falloff anchored to the trailing edge.
///      Previously hard-coded ember inside `NotchTranscriptRow`; it moved here so
///      every state gets it and only one place decides the hue.
///   2. **The bottom lip** — a shallow wash along the bottom edge, masked so it
///      fades to nothing before it reaches the leading edge. That keeps the light
///      physically coherent (it belongs to the bloom) and keeps it off the words,
///      which start at the leading edge and must stay the most readable thing on
///      the band.
///
/// Ember over black goes brown fast, so the strengths in `NotchActivity` are low
/// on purpose. If a state needs to feel more urgent, that is the glyph's job or
/// the copy's — not more light.
///
/// **Nothing here loops.** §6 is explicit that nothing in this system bounces,
/// overshoots, or animates perpetually, and the one breathing element in the app
/// is the record dot, where the breath means "you are live". A pulsing notch would
/// spend that meaning twice. State changes crossfade on the house curve; that is
/// the only motion.
struct NotchGlow: View {
    /// What the band is doing. `.idle` renders nothing at all.
    let activity: NotchActivity

    /// How far in from the trailing edge the bloom reaches. Stops well short of
    /// the words.
    static let bloomWidth: CGFloat = 300
    /// Height of the wash rising off the bottom lip.
    private static let edgeHeight: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Reduce Transparency means "no decorative translucency" — this whole view is
    /// exactly that, so it goes away rather than becoming opaque.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var tint: Color? { activity.accent }
    private var strength: Double { activity.glowStrength }
    private var anchor: UnitPoint { activity.lightAnchor }
    private var isCentred: Bool { anchor == .center }

    var body: some View {
        ZStack {
            if let tint, strength > 0, !reduceTransparency {
                bloom(tint)
                bottomLip(tint)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Crossfade the whole light when the state changes — a hard cut between
        // ember and signal reads as a flicker on a black surface.
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: activity)
    }

    /// The source: an elliptical falloff anchored to the trailing edge, behind the
    /// orb.
    ///
    /// The falloff is deliberately front-loaded — most of the light is spent in the
    /// first third — so the tail is genuinely invisible by the time it reaches the
    /// transcript instead of laying a brown film over it. The last stop is `.clear`
    /// exactly at the frame edge: a gradient that lands on clear *short* of its
    /// frame leaves a visible seam on a black band.
    private func bloom(_ tint: Color) -> some View {
        EllipticalGradient(
            stops: [
                .init(color: tint.opacity(strength), location: 0),
                .init(color: tint.opacity(strength * 0.34), location: 0.32),
                .init(color: tint.opacity(strength * 0.10), location: 0.62),
                .init(color: .clear, location: 1),
            ],
            center: anchor,
            startRadiusFraction: 0,
            endRadiusFraction: 1
        )
        // A centred source needs the full width to fall off symmetrically;
        // anchored at an edge, half of the ellipse is off-surface anyway.
        .frame(width: isCentred ? Self.bloomWidth * 1.6 : Self.bloomWidth)
        .frame(maxWidth: .infinity, alignment: isCentred ? .center : .trailing)
    }

    /// A shallow wash along the bottom lip, so the light looks like it is inside
    /// the surface rather than painted on it — masked to fade out before it reaches
    /// the leading edge, where the words are.
    private func bottomLip(_ tint: Color) -> some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: tint.opacity(strength * 0.30), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Self.edgeHeight)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .mask { lipMask }
    }

    /// Confines the lip to the light's own side of the band: it falls off toward
    /// the leading edge for a trailing source, and toward both edges for a centred
    /// one. Either way it never reaches the words.
    private var lipMask: LinearGradient {
        LinearGradient(
            stops: isCentred
                ? [.init(color: .clear, location: 0),
                   .init(color: .black, location: 0.5),
                   .init(color: .clear, location: 1)]
                : [.init(color: .clear, location: 0),
                   .init(color: .black.opacity(0.35), location: 0.55),
                   .init(color: .black, location: 1)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
