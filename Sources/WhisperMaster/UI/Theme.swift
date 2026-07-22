import SwiftUI

/// The Whisper Master design system — "Daylight": a warm, light, editorial
/// treatment. Paper-cream ground, ink text set in Avenir Next, and a deepened
/// vermillion accent from the app icon spent sparingly. Calm and premium rather
/// than another dark dashboard.
///
/// This is a real token layer, not just colors: spacing (`Space`), radii,
/// elevation (`Shadow` + the `.card()` modifier), semantic status colors, a
/// separate on-dark `Notch` sub-palette for the notch surface, and motion
/// springs (`Motion`). Prefer these tokens over ad-hoc literals so the whole app
/// reads as one intentional object.
enum Theme {
    // MARK: Ground + surfaces (plain white)
    static let canvas = Color.white
    static let canvasTop = Color.white
    /// Slightly off-white for the few boxed elements (tiles, the words field).
    static let surface = Color(red: 0.972, green: 0.968, blue: 0.960)
    static let surfaceSunken = Color(red: 0.925, green: 0.918, blue: 0.902)
    /// Warm sand band used for the selected sidebar item.
    static let selection = Color(red: 0.918, green: 0.882, blue: 0.808)

    // MARK: Ink
    static let textPrimary = Color(red: 0.129, green: 0.110, blue: 0.082)
    static let textSecondary = Color(red: 0.486, green: 0.447, blue: 0.392)
    static let textTertiary = Color(red: 0.655, green: 0.620, blue: 0.557)

    // MARK: Brand / status (deepened for contrast on a light ground)
    static let accent = Color(red: 0.753, green: 0.220, blue: 0.102)
    static let accentSoft = Color(red: 0.753, green: 0.220, blue: 0.102).opacity(0.12)
    static let success = Color(red: 0.235, green: 0.478, blue: 0.306)
    static let successSoft = Color(red: 0.235, green: 0.478, blue: 0.306).opacity(0.12)
    /// Destructive / error — a berry red that reads as *distinct* from the
    /// orange-vermillion accent (they used to be the identical RGB, so a
    /// destructive action was visually indistinguishable from a normal one).
    static let danger = Color(red: 0.706, green: 0.129, blue: 0.145)
    static let dangerSoft = Color(red: 0.706, green: 0.129, blue: 0.145).opacity(0.12)
    /// Caution — a warm amber, for "this is degrading quality" hints (e.g. the
    /// Bluetooth-mic nudge) that aren't errors.
    static let warning = Color(red: 0.804, green: 0.522, blue: 0.114)
    static let warningSoft = Color(red: 0.804, green: 0.522, blue: 0.114).opacity(0.14)

    // MARK: Lines (ink-tinted, not pure black)
    static let stroke = Color(red: 0.129, green: 0.110, blue: 0.082).opacity(0.12)
    static let strokeStrong = Color(red: 0.129, green: 0.110, blue: 0.082).opacity(0.20)

    // MARK: Geometry — radii
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 9
    /// Pills: the sidebar selection band, notch banners, larger chips.
    static let pillRadius: CGFloat = 10
    /// Small chips / tags / inline keycaps.
    static let chipRadius: CGFloat = 7

    // MARK: Spacing scale (8-pt-ish grid — prefer these over raw numbers)
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Elevation
    /// A named shadow so cards can't silently disagree on depth.
    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    /// Standard card lift (used by every grouped card and stat tile).
    static let shadowCard = Shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 4)
    /// A tighter raise for small floating elements.
    static let shadowRaised = Shadow(color: .black.opacity(0.08), radius: 5, x: 0, y: 2)

    // MARK: Motion (one place, so animations stay consistent)
    enum Motion {
        /// Toggle knob slide.
        static let toggle = Animation.spring(response: 0.28, dampingFraction: 0.72)
        /// Content sliding/fading in inside an already-visible surface.
        static let appear = Animation.spring(response: 0.38, dampingFraction: 0.78)
        /// The notch retract.
        static let retract = Animation.spring(response: 0.28, dampingFraction: 0.85)
        /// Wizard/page step transitions.
        static let step = Animation.easeInOut(duration: 0.24)

        /// Returns `base`, or `nil` when Reduce Motion is on — pass straight into
        /// `.animation(_:value:)` so callers honor the accessibility setting with
        /// one call. Read the flag from `@Environment(\.accessibilityReduceMotion)`.
        static func respecting(_ reduceMotion: Bool, _ base: Animation?) -> Animation? {
            reduceMotion ? nil : base
        }
    }

    // MARK: The notch (on-dark) sub-palette
    /// The dark notch band is a legitimately separate context; these are its
    /// tokens so the six banners + the thread stop hardcoding `.white`/`.black`
    /// and can be tuned in one place. Still Avenir Next via `Typography`.
    enum Notch {
        static let surface = Color.black
        static let text = Color.white
        static let textSecondary = Color.white.opacity(0.62)
        static let textTertiary = Color.white.opacity(0.42)
        static let hairline = Color.white.opacity(0.14)
        // NOTE: reconstructed after data loss. These two glass tokens were a
        // manual (non-Claude) edit, so the exact original values could not be
        // recovered from transcripts — tune to taste. Used by the glass pill
        // overlay in DictationPillContent (`.fill(glassSheen)` / `.stroke(glassBorder)`).
        static let glassSheen = LinearGradient(
            colors: [Color.white.opacity(0.18), Color.white.opacity(0.03)],
            startPoint: .top, endPoint: .bottom
        )
        static let glassBorder = Color.white.opacity(0.18)
        static let success = Color(red: 0.55, green: 0.86, blue: 0.62)
        static let danger = Color(red: 1.0, green: 0.52, blue: 0.45)
        static let warning = Color(red: 1.0, green: 0.76, blue: 0.36)
        /// The listening wave: warm cream → white → warm vermillion, so the
        /// most-seen live surface belongs to the brand (it used to be cold blue).
        static let waveGradient = Gradient(colors: [
            Color(red: 1.0, green: 0.84, blue: 0.68),
            .white,
            Color(red: 1.0, green: 0.66, blue: 0.46),
        ])
    }

    // MARK: Ground wash (very subtle warmth, top to bottom)
    static let canvasGradient = LinearGradient(
        colors: [canvasTop, canvas],
        startPoint: .top,
        endPoint: .bottom
    )
    /// AppKit ground color for window backgrounds / titlebars.
    static let canvasNSColor = NSColor.white
}

/// Type system. Display + body are Avenir Next (ships with macOS — no bundling);
/// the utility face is SF Mono for keycaps, versions, and data readouts.
///
/// Every named token carries a `relativeTo:` text style so the UI honors the
/// system Dynamic Type setting (the app used to be fixed-point everywhere and so
/// ignored text-size accessibility entirely).
enum Typography {
    /// The UI sans (Avenir Next) at an explicit weight, scaling relative to a
    /// Dynamic Type text style.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .custom("Avenir Next", size: size, relativeTo: textStyle).weight(weight)
    }

    static let largeTitle = sans(31, .bold, relativeTo: .largeTitle)
    static let title = sans(21, .bold, relativeTo: .title)
    static let headline = sans(15.5, .semibold, relativeTo: .headline)
    static let body = sans(14, .regular, relativeTo: .body)
    static let bodyMedium = sans(14, .medium, relativeTo: .body)
    static let subheadline = sans(13, .regular, relativeTo: .subheadline)
    static let caption = sans(12, .medium, relativeTo: .caption)
    static let kicker = sans(11.5, .bold, relativeTo: .caption2)
    static let label = sans(12, .semibold, relativeTo: .caption)
    /// Big KPI / dashboard numbers (was an inline one-off size in two panels).
    static let metric = sans(34, .bold, relativeTo: .largeTitle)

    // On-notch text — Avenir Next, sized for the dark band.
    static let notchTitle = sans(12, .semibold, relativeTo: .caption)
    static let notchBody = sans(12, .medium, relativeTo: .caption)
    static let notchCaption = sans(10.5, .regular, relativeTo: .caption2)

    static let mono = Font.system(size: 12.5, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
}

// MARK: - Card chrome (one modifier, applied everywhere)

extension View {
    /// The canonical Daylight card chrome: warm surface fill + hairline stroke +
    /// standard lift. Route every card/tile through this so elevation, radius and
    /// border can't drift (they used to be copy-pasted ~5× with mismatched
    /// shadows, so tiles sat flat while grouped cards lifted on the same screen).
    func card(radius: CGFloat = Theme.cardRadius, shadow: Theme.Shadow = Theme.shadowCard) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
            .shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}
