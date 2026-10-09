import AppKit
import CoreText
import SwiftUI

/// 8-bit sRGB convenience — the design tokens are given as hex, so this keeps the
/// palette readable (`Color(255, 242, 235)`).
extension Color {
    init(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) {
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: a)
    }
}

/// The Whisper Master design system — **"Organic"**: a warm, glassmorphic
/// treatment. Cream ground, ink text, a spent-sparingly terracotta accent and a
/// sage second accent, frosted-glass cards floating over a soft warm-blob
/// gradient. Display type is Caprasimo; body/UI type is Figtree (both bundled).
enum Theme {
    // MARK: Ground + surfaces
    /// Cream ground `#f5ead8`.
    static let canvas = Color(245, 234, 216)
    /// Slightly lighter cream for the top of the ground wash.
    static let canvasTop = Color(250, 241, 226)
    /// Warm near-white for lifted opaque elements (tiles, badges, ghost buttons).
    static let surface = Color(251, 245, 236)
    /// Sunken warm sand for pressed/inset controls.
    static let surfaceSunken = Color(238, 226, 205)
    /// Warm tint behind a selected sidebar row (used when glass isn't wanted).
    static let selection = Color(243, 221, 201)

    // MARK: Ink
    /// Near-black ink `#201e1d`.
    static let textPrimary = Color(32, 30, 29)
    /// Muted brown-grey for secondary copy.
    static let textSecondary = Color(116, 106, 88)
    /// Faint brown-grey for captions / tertiary marks.
    static let textTertiary = Color(154, 140, 119)

    // MARK: Brand / status
    /// Terracotta accent `#c67139`.
    static let accent = Color(198, 113, 57)
    /// A wash of accent for soft fills / halos.
    static let accentSoft = Color(198, 113, 57).opacity(0.14)
    /// Sage second accent `#7a8a5e`.
    static let accent2 = Color(122, 138, 94)
    /// Muted green for "connected"/"granted" affirmatives.
    static let success = Color(90, 120, 74)
    /// Reuse the terracotta for destructive marks (kept warm, not a cold red).
    static let danger = Color(178, 74, 52)

    // MARK: Lines (ink-tinted @ ~16% / ~28%)
    static let stroke = Color(32, 30, 29).opacity(0.14)
    static let strokeStrong = Color(32, 30, 29).opacity(0.26)

    // MARK: Geometry (design cards sit at 18–26; chips at 12)
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 12
    static let panelRadius: CGFloat = 28

    // MARK: Warm shadows (`rgba(46,43,37, ·)`)
    static let shadowColor = Color(46, 43, 37)
    static let softShadow = Color(46, 43, 37).opacity(0.12)
    static let liftShadow = Color(46, 43, 37).opacity(0.16)

    // MARK: Ground wash (subtle top-to-bottom warmth — kept for legacy call-sites;
    // the window shell uses `WarmBackground` for the blob gradient).
    static let canvasGradient = LinearGradient(
        colors: [canvasTop, canvas],
        startPoint: .top,
        endPoint: .bottom
    )

    /// AppKit ground color for window / titlebar backgrounds — the cream ground.
    static let canvasNSColor = NSColor(srgbRed: 245.0 / 255, green: 234.0 / 255, blue: 216.0 / 255, alpha: 1)

    // MARK: Tonal ramps (nested enums — `Theme.Accent.n300`, etc.)

    /// Terracotta ramp `accent-100 … accent-900` (`#fff2eb … #402310`).
    enum Accent {
        static let n100 = Color(255, 242, 235)
        static let n200 = Color(255, 224, 204)
        static let n300 = Color(246, 193, 155)
        static let n400 = Color(227, 154, 103)
        static let n500 = Color(198, 113, 57)
        static let n600 = Color(168, 90, 43)
        static let n700 = Color(131, 68, 32)
        static let n800 = Color(95, 49, 23)
        static let n900 = Color(64, 35, 16)
    }

    /// Sage ramp `accent-2-100 … accent-2-900`.
    enum Accent2 {
        static let n100 = Color(241, 243, 234)
        static let n200 = Color(221, 227, 205)
        static let n300 = Color(195, 205, 169)
        static let n400 = Color(161, 176, 127)
        static let n500 = Color(122, 138, 94)
        static let n600 = Color(99, 115, 74)
        static let n700 = Color(76, 89, 57)
        static let n800 = Color(56, 65, 41)
        static let n900 = Color(38, 44, 27)
    }

    /// Neutral warm-grey ramp `neutral-100 … neutral-900` (`#f9f4ed … #2e2b25`).
    enum Neutral {
        static let n100 = Color(249, 244, 237)
        static let n200 = Color(239, 231, 218)
        static let n300 = Color(221, 210, 190)
        static let n400 = Color(191, 178, 155)
        static let n500 = Color(154, 140, 119)
        static let n600 = Color(116, 106, 88)
        static let n700 = Color(84, 76, 63)
        static let n800 = Color(59, 53, 44)
        static let n900 = Color(46, 43, 37)
    }

    // MARK: On-dark notch sub-palette (the design's notch stays dark)
    enum Notch {
        /// The band behind notch content is pure black to fuse with the bezel.
        static let band = Color.black
        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.72)
        static let textTertiary = Color.white.opacity(0.5)
        /// Warm terracotta→amber wave used for the live waveform / accents.
        static let wave = LinearGradient(
            colors: [Color(227, 154, 103), Color(198, 113, 57)],
            startPoint: .top,
            endPoint: .bottom
        )
        static let accent = Color(227, 154, 103)
        /// Translucent keycap fill on the dark band.
        static let keycap = Color.white.opacity(0.12)
        static let keycapStroke = Color.white.opacity(0.22)
    }
}

// MARK: - Fonts

/// Registers and resolves the two bundled faces — **Caprasimo** (display) and
/// **Figtree** (body/UI). Registration happens once, lazily, the first time any
/// `Typography` token is built, so it's safe in the app, snapshots, and tests.
/// If a face can't be found/registered, `Typography` falls back to the system
/// font and the app still renders.
enum BrandFonts {
    // The bundled Figtree static faces carry the odd fontsource family name
    // "Figtree Light"; we reference each face by its unambiguous PostScript name.
    static let caprasimo = "Caprasimo-Regular"
    static let figtreeRegular = "FigtreeLight-Regular"
    static let figtreeMedium = "FigtreeLight-Medium"
    static let figtreeSemibold = "FigtreeLight-SemiBold"
    static let figtreeBold = "FigtreeLight-Bold"

    /// The resource filenames (without extension) of every bundled face.
    private static let files = [
        "Caprasimo-Regular",
        "Figtree-Regular",
        "Figtree-Medium",
        "Figtree-SemiBold",
        "Figtree-Bold",
    ]

    /// Registered exactly once (static-let semantics). `true` when the display
    /// face is available; drives the Caprasimo-vs-system fallback.
    static let hasCaprasimo: Bool = { registerAll(); return isAvailable(caprasimo) }()
    /// `true` when the Figtree regular face is available.
    static let hasFigtree: Bool = { registerAll(); return isAvailable(figtreeRegular) }()

    /// Idempotent one-shot registration of all bundled faces.
    private static let didRegister: Bool = {
        for file in files {
            guard let url = BrandAsset.resourceURL(named: file, withExtension: "ttf") else { continue }
            var error: Unmanaged<CFError>?
            // Already-registered (e.g. a second snapshot pass) reports an error we
            // deliberately ignore — the face is usable either way.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
        return true
    }()

    /// Force registration; callable from `applicationDidFinishLaunching`.
    static func registerAll() { _ = didRegister }

    private static func isAvailable(_ postScriptName: String) -> Bool {
        NSFont(name: postScriptName, size: 12) != nil
    }
}

/// Type system — **Caprasimo** for display, **Figtree** for body/UI, `SF Mono`
/// for keycaps / versions / data readouts. Every token name here is load-bearing
/// (call-sites across the app reference them); keep them all.
enum Typography {
    /// The body/UI sans (Figtree) at an explicit weight, falling back to the
    /// system font when the bundled face isn't available.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard BrandFonts.hasFigtree else { return .system(size: size, weight: weight) }
        return .custom(figtreePostScriptName(for: weight), size: size)
    }

    /// The display serif (Caprasimo — a single weight), falling back to the
    /// system rounded face. Caprasimo ignores `weight`; the parameter is kept so
    /// heading tokens read naturally.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard BrandFonts.hasCaprasimo else { return .system(size: size, weight: .bold, design: .rounded) }
        return .custom(BrandFonts.caprasimo, size: size)
    }

    private static func figtreePostScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .semibold: return BrandFonts.figtreeSemibold
        case .bold, .heavy, .black: return BrandFonts.figtreeBold
        case .medium: return BrandFonts.figtreeMedium
        default: return BrandFonts.figtreeRegular
        }
    }

    // Display (Caprasimo)
    static let largeTitle = display(32)
    static let title = display(22)
    // Headline stays on the body face at semibold — Caprasimo is a chunky
    // display serif and reads poorly at row-label sizes; a deliberate legibility
    // choice over the design's "everything display" note.
    static let headline = sans(15.5, .semibold)

    // Body / UI (Figtree)
    static let body = sans(14, .regular)
    static let bodyMedium = sans(14, .medium)
    static let subheadline = sans(13, .regular)
    static let caption = sans(12, .medium)
    static let kicker = sans(11.5, .bold)
    static let label = sans(12, .semibold)

    // Data / keycaps (SF Mono)
    static let mono = Font.system(size: 12.5, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
}

// MARK: - Glass primitives

/// The warm blob-gradient ground the whole window sits on: cream base with a few
/// soft, low-opacity terracotta/sage radial blooms.
struct WarmBackground: View {
    var body: some View {
        ZStack {
            Theme.canvas
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                ZStack {
                    blob(Theme.Accent.n300.opacity(0.55), size: max(w, h) * 0.9)
                        .position(x: w * 0.12, y: h * 0.08)
                    blob(Theme.Accent2.n300.opacity(0.5), size: max(w, h) * 0.85)
                        .position(x: w * 0.95, y: h * 0.28)
                    blob(Theme.Accent.n200.opacity(0.5), size: max(w, h) * 0.8)
                        .position(x: w * 0.75, y: h * 1.02)
                    blob(Theme.Accent2.n200.opacity(0.4), size: max(w, h) * 0.7)
                        .position(x: w * 0.05, y: h * 0.95)
                }
                .blur(radius: 8)
            }
        }
        .ignoresSafeArea()
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        RadialGradient(
            colors: [color, color.opacity(0)],
            center: .center,
            startRadius: 0,
            endRadius: size / 2
        )
        .frame(width: size, height: size)
    }
}

/// Frosted-glass surface: translucent white tint over `.ultraThinMaterial`, a
/// white hairline stroke, a top sheen, and a soft warm drop shadow. Faithful to
/// the CSS `backdrop-filter` glass, though not pixel-identical.
private struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Double
    var shadow: Color
    var shadowRadius: CGFloat
    var shadowY: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                shape
                    .fill(Color.white.opacity(tint))
                    .background(.ultraThinMaterial, in: shape)
            }
            .overlay {
                // Top sheen — a bright hairline of light rolling off the top edge.
                shape
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.55), Color.white.opacity(0)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
            }
            .clipShape(shape)
            .shadow(color: shadow, radius: shadowRadius, x: 0, y: shadowY)
    }
}

extension View {
    /// A frosted-glass card — the standard content surface in the Organic theme.
    func glassCard(cornerRadius: CGFloat = Theme.cardRadius, tint: Double = 0.34) -> some View {
        modifier(GlassSurface(
            cornerRadius: cornerRadius,
            tint: tint,
            shadow: Theme.softShadow,
            shadowRadius: 16,
            shadowY: 8
        ))
    }

    /// A larger, slightly heavier glass panel — the window shell / big containers.
    func glassPanel(cornerRadius: CGFloat = Theme.panelRadius, tint: Double = 0.26) -> some View {
        modifier(GlassSurface(
            cornerRadius: cornerRadius,
            tint: tint,
            shadow: Theme.liftShadow,
            shadowRadius: 30,
            shadowY: 14
        ))
    }
}
