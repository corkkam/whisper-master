import SwiftUI

// MARK: - The button ladder
//
// Six rungs, in descending emphasis, plus an icon button. Each carries **one
// sentence of intent and the places it belongs**, so picking a button is a lookup
// rather than a judgement call — and so a screen with three competing pills reads
// as obviously wrong.
//
//   primary      →  the one action this screen exists for. One per view, maximum.
//   secondary    →  supporting actions that still need a filled target.
//   outlined     →  medium emphasis where a border has to define the bounds.
//   ghost        →  low emphasis: nothing at rest, a fill on hover.
//   text         →  lowest: no background in any state, only the ink changes.
//   destructive  →  irreversible actions. Danger-tinted, never ember.
//   icon         →  a glyph-only control, with a tooltip and a real a11y label.
//
// Everything shared lives in `LadderButtonBody`: the pill geometry, the hover
// lift, the state layers, the disabled treatment, the pointer cursor, and Reduce
// Motion. Add a rung by extending `ButtonRung`, not by writing another
// `ButtonStyle` from scratch.
//
// House rules these encode (`docs/07-design-system.md`):
//   §1  ember = the human, signal = the machine. A *button* is the user acting,
//       so the primary fill is ember; signal stays on machine state and success.
//   §4  buttons are fully round. Nothing here has a 6px rounded rect.
//   §6  hover lifts 2px on the house curve. Nothing bounces, nothing scales,
//       nothing loops — the breathing ring belongs to the record dot alone.

/// Which rung of the ladder a button sits on.
enum ButtonRung {
    case primary, secondary, outlined, ghost, text, destructive
}

// MARK: - The always-dark surface

private struct OnDarkSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a surface that is always ink regardless of the app's
    /// light/dark setting — the notch band and the onboarding band, which sit on
    /// the physical black bezel.
    var isOnDarkSurface: Bool {
        get { self[OnDarkSurfaceKey.self] }
        set { self[OnDarkSurfaceKey.self] = newValue }
    }
}

extension View {
    /// Marks a subtree as living on the always-dark band, so every ladder button
    /// inside it draws from `Theme.Notch` instead of the mode-dependent tokens.
    ///
    /// Without this, a light-mode window would put `textPrimary` (near-black ink)
    /// on a pitch-black band. Apply it once at the band's root — not per button.
    func onDarkSurface() -> some View {
        environment(\.isOnDarkSurface, true)
    }
}

// MARK: - Styles

/// The one action a screen exists for — an ember pill whose label sits in its own
/// near-black tint. **One per view.** Used for: "Continue" in onboarding, "Grant
/// access", "Retry" on a failed model load.
struct PrimaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        LadderButtonBody(configuration: configuration, rung: .primary, isFullWidth: isFullWidth)
    }
}

/// A supporting action that still needs a filled target: glass fill, hairline
/// ring. Used for: "Copy", "Open System Settings", the second button in a pair.
struct SecondaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        LadderButtonBody(configuration: configuration, rung: .secondary, isFullWidth: isFullWidth)
    }
}

/// Medium emphasis where the button's bounds have to be legible before hover —
/// a hairline with no fill. Used for: pickers, "Add…" affordances in a dense row.
struct OutlinedButtonStyle: ButtonStyle {
    var isFullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        LadderButtonBody(configuration: configuration, rung: .outlined, isFullWidth: isFullWidth)
    }
}

/// Low emphasis: nothing at rest, a state-layer fill on hover. Used for: sidebar
/// and nav items, list-row affordances, anything repeated many times down a page.
struct GhostButtonStyle: ButtonStyle {
    var isFullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        LadderButtonBody(configuration: configuration, rung: .ghost, isFullWidth: isFullWidth)
    }
}

/// The lowest rung: **no background in any state, not even hover** — only the ink
/// changes. Used for: "Skip", "Not now", "Cancel", inline "Learn more".
struct TextButtonStyle: ButtonStyle {
    var isFullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        LadderButtonBody(configuration: configuration, rung: .text, isFullWidth: isFullWidth)
    }
}

/// Irreversible actions — delete a transcript, clear history, sign out. Danger
/// tinted and intensifying through hover into press, so the weight of the action
/// is visible before the click. Never ember: ember means *you are live*.
struct DestructiveButtonStyle: ButtonStyle {
    var isFullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        LadderButtonBody(configuration: configuration, rung: .destructive, isFullWidth: isFullWidth)
    }
}

/// How loudly an icon button carries danger.
enum IconButtonTone {
    /// The default: secondary glyph, primary on hover.
    case neutral
    /// Danger-coloured at rest — for a delete whose target is not obvious from
    /// the glyph alone, where the colour is doing real work.
    case destructive
    /// Neutral at rest, danger on hover — for a destructive action repeated down
    /// a list, where a permanently red glyph would shout from every row.
    case destructiveOnHover
}

/// A glyph-only control: a quiet rounded square that fills on hover.
///
/// `tooltip` uses the AppKit bridge rather than `.help()`, because this style
/// tracks hover itself. A tooltip is **not** an accessibility label — set
/// `.accessibilityLabel` at the call site too (`IconButton` does both).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var tone: IconButtonTone = .neutral
    var tooltip: String?

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, size: size, tone: tone, tooltip: tooltip)
    }

    /// The inner view exists so `@Environment` and `@State` actually update —
    /// `makeBody` is not a `View` body, so property wrappers declared on the
    /// style itself never refresh. It can't be called `Body`: that name collides
    /// with `ButtonStyle`'s own associated type.
    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let tone: IconButtonTone
        let tooltip: String?

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isOnDarkSurface) private var isOnDarkSurface
        @State private var isHovering = false

        private var isHot: Bool { isHovering && isEnabled }

        private var inkPrimary: Color { isOnDarkSurface ? Theme.Notch.text : Theme.textPrimary }
        private var inkSecondary: Color { isOnDarkSurface ? Theme.Notch.textSecondary : Theme.textSecondary }
        private var dangerInk: Color { isOnDarkSurface ? Theme.Notch.danger : Theme.danger }
        private var layerTint: Color {
            isOnDarkSurface ? Theme.Notch.stateLayerTint : Theme.StateLayer.tint
        }

        private var glyphColor: Color {
            guard isEnabled else { return inkPrimary.opacity(Theme.StateLayer.disabledContent) }
            switch tone {
            case .destructive: return dangerInk
            case .destructiveOnHover: return isHot ? dangerInk : inkSecondary
            case .neutral: return isHot ? inkPrimary : inkSecondary
            }
        }

        /// Danger tones fill with `dangerSoft` so the hover reads as a warning,
        /// not just as "something is under the pointer".
        private var isDangerFill: Bool {
            isHot && tone != .neutral
        }

        private var fillOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return Theme.StateLayer.pressed }
            return isHovering ? Theme.StateLayer.hover : 0
        }

        var body: some View {
            configuration.label
                .foregroundStyle(glyphColor)
                .frame(width: size, height: size)
                .background {
                    RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                        .fill(isDangerFill ? Theme.dangerSoft : layerTint.opacity(fillOpacity))
                }
                .contentShape(Rectangle())
                .onHover { hovering in
                    guard isEnabled else { return }
                    isHovering = hovering
                }
                .animation(
                    Theme.Motion.respecting(reduceMotion, Theme.Motion.quick),
                    value: isHovering
                )
                .pointerCursor(isEnabled: isEnabled)
                .nativeTooltip(tooltip)
        }
    }
}

// MARK: - The one shared body

/// Every rung's geometry, states and motion in one place, so hover strength and
/// press feedback can't drift apart between buttons.
private struct LadderButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let rung: ButtonRung
    let isFullWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isOnDarkSurface) private var isOnDarkSurface
    @State private var isHovering = false

    private var isPressed: Bool { configuration.isPressed }
    /// Hover only counts while the control can actually be used.
    private var isHot: Bool { isHovering && isEnabled }

    // MARK: Surface-scoped tokens
    //
    // One switch per token instead of a branch at every use, so the on-band
    // variant can't half-apply. Ember, danger-as-a-hue and the accent-on colour
    // are the same on both surfaces — the palette doesn't change, only the ground
    // it is read against does.

    private var inkPrimary: Color { isOnDarkSurface ? Theme.Notch.text : Theme.textPrimary }
    private var inkSecondary: Color { isOnDarkSurface ? Theme.Notch.textSecondary : Theme.textSecondary }
    private var hairline: Color { isOnDarkSurface ? Theme.Notch.glassBorder : Theme.line }
    private var hairlineStrong: Color {
        isOnDarkSurface ? Color.white.opacity(0.18) : Theme.strokeStrong
    }
    private var controlFill: Color { isOnDarkSurface ? Theme.Notch.controlFill : Theme.surfaceGlass }
    private var controlFillPressed: Color {
        isOnDarkSurface ? Theme.Notch.controlFillPressed : Theme.surfaceGlass2
    }
    private var dangerInk: Color { isOnDarkSurface ? Theme.Notch.danger : Theme.danger }
    private var accentInk: Color { isOnDarkSurface ? Theme.Notch.accent : Theme.accent }
    private var layerTint: Color {
        isOnDarkSurface ? Theme.Notch.stateLayerTint : Theme.StateLayer.tint
    }

    var body: some View {
        configuration.label
            .font(Typography.bodyMedium)
            .foregroundStyle(foreground)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background { fill }
            .overlay { stateLayer }
            .overlay { border }
            .clipShape(Capsule(style: .continuous))
            .modifier(GlowShadow(shadow: glow))
            .offset(y: liftOffset)
            .contentShape(Capsule(style: .continuous))
            .onHover { hovering in
                guard isEnabled else { return }
                isHovering = hovering
            }
            .animation(
                Theme.Motion.respecting(reduceMotion, Theme.Motion.quick),
                value: isHovering
            )
            .animation(
                Theme.Motion.respecting(reduceMotion, Theme.Motion.quick),
                value: isPressed
            )
            .pointerCursor(isEnabled: isEnabled)
    }

    // MARK: Geometry

    /// The text rung has no background to pad against, so it only takes enough
    /// inset to keep a comfortable hit target.
    private var horizontalPadding: CGFloat { rung == .text ? Theme.Space.sm : 18 }
    private var verticalPadding: CGFloat { rung == .text ? 6 : 9 }

    /// 2px up on hover, back to rest under the finger. The text rung doesn't
    /// lift — with no surface to lift, it just makes the label twitch.
    private var liftOffset: CGFloat {
        guard rung != .text, isHot, !isPressed else { return 0 }
        return Theme.StateLayer.lift
    }

    // MARK: Ink

    private var foreground: Color {
        guard isEnabled else { return inkPrimary.opacity(Theme.StateLayer.disabledContent) }
        switch rung {
        case .primary:
            // Never white: white on ember is 2.5:1. The label is a near-black
            // tint of the accent's own hue.
            return Theme.accentOn
        case .secondary, .outlined:
            return inkPrimary
        case .ghost:
            return isHot ? inkPrimary : inkSecondary
        case .text:
            // Only the ink moves on this rung — so it has to move enough to read.
            return isHot ? accentInk : inkSecondary
        case .destructive:
            return dangerInk
        }
    }

    // MARK: Surface

    @ViewBuilder
    private var fill: some View {
        let shape = Capsule(style: .continuous)
        if !isEnabled {
            switch rung {
            case .primary, .secondary, .destructive:
                shape.fill(layerTint.opacity(Theme.StateLayer.disabledContainer))
            case .outlined, .ghost, .text:
                shape.fill(.clear)
            }
        } else {
            switch rung {
            case .primary:
                // The accent ramp *is* the press feedback here: a state layer over
                // ember only muddies the hue.
                shape.fill(isPressed ? Theme.Ember.deep : (isHot ? Theme.Ember.bright : Theme.accentFill))
            case .secondary:
                shape.fill(isPressed ? controlFillPressed : controlFill)
            case .destructive:
                shape.fill(Theme.dangerSoft)
            case .outlined, .ghost, .text:
                shape.fill(.clear)
            }
        }
    }

    /// The tint overlay that carries hover/press on the rungs whose own fill
    /// doesn't. Primary is excluded (it moves along the ember ramp instead) and so
    /// is text (which by definition never gains a background).
    @ViewBuilder
    private var stateLayer: some View {
        if isEnabled, rung != .primary, rung != .text, stateLayerOpacity > 0 {
            Capsule(style: .continuous)
                .fill(stateLayerTint.opacity(stateLayerOpacity))
                .allowsHitTesting(false)
        }
    }

    private var stateLayerTint: Color {
        rung == .destructive ? dangerInk : layerTint
    }

    private var stateLayerOpacity: Double {
        if isPressed { return Theme.StateLayer.pressed }
        return isHot ? Theme.StateLayer.hover : 0
    }

    @ViewBuilder
    private var border: some View {
        switch rung {
        case .secondary, .outlined:
            Capsule(style: .continuous)
                .strokeBorder(isHot ? hairlineStrong : hairline, lineWidth: 1)
                .allowsHitTesting(false)
        case .primary, .ghost, .text, .destructive:
            EmptyView()
        }
    }

    /// Elevation on the primary rung only, and as an **accent-tinted glow rather
    /// than a brighter border** (§4). It settles under the press, so the button
    /// reads as pushed into the surface.
    private var glow: Theme.Shadow? {
        guard rung == .primary, isEnabled else { return nil }
        let strength: Double = isPressed ? 0 : (isHot ? 0.55 : 0.45)
        return Theme.Shadow(color: Theme.Ember.base.opacity(strength), radius: 18, x: 0, y: 8)
    }
}

/// Applies a `Theme.Shadow` when there is one — a `.shadow` with a clear colour
/// still costs a render pass, so the nil case skips the modifier entirely.
private struct GlowShadow: ViewModifier {
    let shadow: Theme.Shadow?

    func body(content: Content) -> some View {
        if let shadow {
            content.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
        } else {
            content
        }
    }
}

// MARK: - Call-site ergonomics

extension View {
    /// The one action this screen exists for. One per view.
    func primaryButton(isFullWidth: Bool = false) -> some View {
        buttonStyle(PrimaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// A supporting action that still needs a filled target.
    func secondaryButton(isFullWidth: Bool = false) -> some View {
        buttonStyle(SecondaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// Medium emphasis, bounds defined by a hairline.
    func outlinedButton(isFullWidth: Bool = false) -> some View {
        buttonStyle(OutlinedButtonStyle(isFullWidth: isFullWidth))
    }

    /// Low emphasis: nothing at rest, a fill on hover.
    func ghostButton(isFullWidth: Bool = false) -> some View {
        buttonStyle(GhostButtonStyle(isFullWidth: isFullWidth))
    }

    /// Lowest emphasis: no background, ever.
    func textButton(isFullWidth: Bool = false) -> some View {
        buttonStyle(TextButtonStyle(isFullWidth: isFullWidth))
    }

    /// Irreversible actions.
    func destructiveButton(isFullWidth: Bool = false) -> some View {
        buttonStyle(DestructiveButtonStyle(isFullWidth: isFullWidth))
    }

    /// A glyph-only control. Pair with `.accessibilityLabel` — the tooltip is not
    /// a substitute for one.
    func iconButton(size: CGFloat = 30, tone: IconButtonTone = .neutral, tooltip: String? = nil) -> some View {
        buttonStyle(IconButtonStyle(size: size, tone: tone, tooltip: tooltip))
    }
}
