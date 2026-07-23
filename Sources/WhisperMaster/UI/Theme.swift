import AppKit
import SwiftUI

// MARK: - Hex helper

extension Color {
    /// Build a Color from a 24-bit RGB hex, e.g. `Color(hex: 0xc67139)`.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

/// The Whisper Master design system — **"Organic"**: a warm, tactile, glass
/// treatment. A paper-cream ground washed with soft accent blooms, frosted-glass
/// cards that lift off it, a toasted-orange accent and a sage secondary, set in
/// Caprasimo (display) over Figtree (text). Calm, hand-made and premium rather
/// than another flat dashboard.
///
/// This is a real token layer, not just colors: the two accent ramps
/// (`Theme.Accent` / `Theme.Sage`) and a neutral ramp, spacing (`Space`), radii,
/// elevation (`Shadow` + `.card()`/`.glassCard()`), semantic status colors, the
/// on-dark `Notch` sub-palette, glass surface helpers, the `WarmBackground`
/// ground, and motion springs (`Motion`). Prefer these tokens over ad-hoc
/// literals so the whole app reads as one intentional object.
enum Theme {
    // MARK: Tonal ramps (from the design system tokens)

    /// The toasted-orange primary ramp.
    enum Accent {
        static let n100 = Color(hex: 0xfff2eb)
        static let n200 = Color(hex: 0xffe1d0)
        static let n300 = Color(hex: 0xffc6a5)
        static let n400 = Color(hex: 0xf6a06b)
        static let n500 = Color(hex: 0xd67f48)
        static let n600 = Color(hex: 0xb2622d)
        static let n700 = Color(hex: 0x8c491a)
        static let n800 = Color(hex: 0x643312)
        static let n900 = Color(hex: 0x402310)
    }

    /// The sage secondary ramp (`--color-accent-2`).
    enum Sage {
        static let n100 = Color(hex: 0xf0fae1)
        static let n200 = Color(hex: 0xe1eecc)
        static let n300 = Color(hex: 0xccdbb2)
        static let n400 = Color(hex: 0xaebf92)
        static let n500 = Color(hex: 0x8fa073)
        static let n600 = Color(hex: 0x728157)
        static let n700 = Color(hex: 0x56633f)
        static let n800 = Color(hex: 0x3d472b)
        static let n900 = Color(hex: 0x272e1b)
    }

    /// The warm neutral ramp.
    enum Neutral {
        static let n100 = Color(hex: 0xf9f4ed)
        static let n200 = Color(hex: 0xeee7db)
        static let n300 = Color(hex: 0xdcd3c4)
        static let n400 = Color(hex: 0xc0b6a5)
        static let n500 = Color(hex: 0xa19786)
        static let n600 = Color(hex: 0x82796a)
        static let n700 = Color(hex: 0x645c50)
        static let n800 = Color(hex: 0x474238)
        static let n900 = Color(hex: 0x2e2b25)
    }

    // MARK: Ground + surfaces

    /// The paper-cream ground (`--color-bg`).
    static let canvas = Color(hex: 0xf5ead8)
    static let canvasTop = Color(hex: 0xf4e8d0)
    /// A soft warm off-white for solid (non-glass) tiles.
    static let surface = Neutral.n100
    static let surfaceSunken = Neutral.n200
    /// Translucent white band used for the selected sidebar item (glass).
    static let selection = Color.white.opacity(0.5)

    /// The translucent white used to tint frosted-glass cards.
    static let glassFill = Color.white
    /// The bright hairline that rings a glass card (the design's `#fff 55%`).
    static let glassBorderColor = Color.white.opacity(0.55)

    // MARK: Ink
    static let textPrimary = Color(hex: 0x201e1d)
    static let textSecondary = Color(hex: 0x201e1d, alpha: 0.64)
    static let textTertiary = Color(hex: 0x201e1d, alpha: 0.45)

    // MARK: Brand / status
    static let accent = Color(hex: 0xc67139)
    static let accentSoft = Color(hex: 0xc67139, alpha: 0.12)
    /// Deepened accent for text/kickers on the light ground (better contrast).
    static let accentText = Accent.n700
    /// The sage secondary.
    static let accent2 = Color(hex: 0x7a8a5e)
    static let accent2Soft = Color(hex: 0x7a8a5e, alpha: 0.14)

    static let success = Sage.n600
    static let successSoft = Color(hex: 0x728157, alpha: 0.16)
    /// Destructive / error — a berry red that reads as *distinct* from the
    /// orange accent.
    static let danger = Color(red: 0.706, green: 0.129, blue: 0.145)
    static let dangerSoft = Color(red: 0.706, green: 0.129, blue: 0.145).opacity(0.12)
    /// Caution — a warm amber for degrade hints (e.g. the Bluetooth nudge).
    static let warning = Color(red: 0.804, green: 0.522, blue: 0.114)
    static let warningSoft = Color(red: 0.804, green: 0.522, blue: 0.114).opacity(0.16)

    // MARK: Lines (ink-tinted, not pure black)
    static let stroke = Color(hex: 0x201e1d, alpha: 0.10)
    static let strokeStrong = Color(hex: 0x201e1d, alpha: 0.18)

    // MARK: Geometry — radii (rounder, softer than Daylight)
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 12
    /// Pills: the sidebar selection band, larger chips.
    static let pillRadius: CGFloat = 14
    /// Small chips / tags / inline keycaps.
    static let chipRadius: CGFloat = 11

    // MARK: Spacing scale (prefer these over raw numbers)
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Elevation (warm, tuned to the cream ground)
    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    /// Standard glass-card lift.
    static let shadowCard = Shadow(color: Color(hex: 0x2e2b25, alpha: 0.14), radius: 22, x: 0, y: 11)
    /// A tighter raise for small floating elements.
    static let shadowRaised = Shadow(color: Color(hex: 0x2e2b25, alpha: 0.16), radius: 10, x: 0, y: 4)
    /// The big lift under the main window panel.
    static let shadowPanel = Shadow(color: Color(hex: 0x2e2b25, alpha: 0.30), radius: 60, x: 0, y: 34)

    // MARK: Motion (one place, so animations stay consistent)
    enum Motion {
        static let toggle = Animation.spring(response: 0.28, dampingFraction: 0.72)
        static let appear = Animation.spring(response: 0.38, dampingFraction: 0.78)
        static let retract = Animation.spring(response: 0.28, dampingFraction: 0.85)
        static let step = Animation.easeInOut(duration: 0.24)

        /// Returns `base`, or `nil` when Reduce Motion is on.
        static func respecting(_ reduceMotion: Bool, _ base: Animation?) -> Animation? {
            reduceMotion ? nil : base
        }
    }

    // MARK: The notch (on-dark) sub-palette
    /// The dark notch band is a legitimately separate context; these are its
    /// tokens so the banners + the pill stop hardcoding `.white`/`.black`.
    enum Notch {
        /// Deep espresso-black so the band reads as molded into the bezel.
        static let surface = Color(hex: 0x161310)
        static let text = Color(hex: 0xf6eddd)
        static let textSecondary = Color(hex: 0xf6eddd, alpha: 0.66)
        static let textTertiary = Color(hex: 0xf6eddd, alpha: 0.44)
        static let hairline = Color.white.opacity(0.16)
        static let glassSheen = LinearGradient(
            colors: [Color.white.opacity(0.18), Color.clear],
            startPoint: .top, endPoint: .bottom
        )
        static let glassBorder = Color.white.opacity(0.16)
        static let success = Sage.n300
        static let danger = Color(red: 1.0, green: 0.52, blue: 0.45)
        static let warning = Color(red: 1.0, green: 0.76, blue: 0.36)
        /// The live listening wave — warm cream → accent, matching the design.
        static let waveGradient = Gradient(colors: [Accent.n300, Accent.n400])
        /// The accent used for the live dot / cursor on the band.
        static let accent = Accent.n400
    }

    // MARK: Ground wash
    /// A flat warm gradient fallback (the full ground is `WarmBackground`).
    static let canvasGradient = LinearGradient(
        colors: [Color(hex: 0xf4e8d0), Color(hex: 0xecdfc4), Color(hex: 0xe2d3b3)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// AppKit ground color for window backgrounds / titlebars.
    static let canvasNSColor = NSColor(srgbRed: 0.945, green: 0.906, blue: 0.804, alpha: 1) // ~#f1e7cd
}

// MARK: - Fonts

/// Resolves the bundled brand faces, registering them once and falling back to
/// the closest system faces if a file is missing (so the app never renders
/// blank text). Registration happens at launch via `registerAll()`.
enum BrandFont {
    static let heading = "Caprasimo"
    static let body = "Figtree"

    /// Register every `.ttf` in the resource bundle's `Fonts/` folder with Core
    /// Text (process-scoped). Idempotent; safe to call at launch.
    static func registerAll() {
        guard let bundle = resourceBundle else { return }
        let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// True once the named family is resolvable by AppKit.
    static var hasHeading: Bool { NSFont(name: heading, size: 12) != nil }
    static var hasBody: Bool { NSFont(name: body, size: 12) != nil }

    /// Reuse the same bundle probe as `BrandAsset` (SwiftPM resource bundle).
    private static var resourceBundle: Bundle? {
        let name = "WhisperMaster_WhisperMaster.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
        ]
        for url in candidates.compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.main
    }
}

/// Type system. Display/titles are **Caprasimo** (a rounded display face);
/// body/UI text is **Figtree**; the utility face is SF Mono for keycaps,
/// versions and data readouts. Both brand faces are bundled and registered at
/// launch; if unavailable they fall back to system faces.
///
/// Every named token carries a `relativeTo:` text style so the UI honors the
/// system Dynamic Type setting.
enum Typography {
    /// The UI/body sans (Figtree) at an explicit weight, scaling relative to a
    /// Dynamic Type text style. Falls back to the system sans.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        if BrandFont.hasBody {
            return .custom(BrandFont.body, size: size, relativeTo: textStyle).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    /// The display/heading face (Caprasimo, single weight). Falls back to a
    /// rounded bold system face so headings still read as display type.
    static func heading(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .title) -> Font {
        if BrandFont.hasHeading {
            return .custom(BrandFont.heading, size: size, relativeTo: textStyle)
        }
        return .system(size: size, weight: .bold, design: .rounded)
    }

    // Display / headings — Caprasimo.
    static let largeTitle = heading(38, relativeTo: .largeTitle)
    static let title = heading(24, relativeTo: .title)
    static let headline = heading(16, relativeTo: .headline)
    /// Big KPI / dashboard numbers.
    static let metric = heading(34, relativeTo: .largeTitle)

    // Body / UI — Figtree.
    static let body = sans(14.5, .regular, relativeTo: .body)
    static let bodyMedium = sans(14.5, .medium, relativeTo: .body)
    static let subheadline = sans(13, .regular, relativeTo: .subheadline)
    static let caption = sans(12, .medium, relativeTo: .caption)
    static let kicker = sans(11, .bold, relativeTo: .caption2)
    static let label = sans(12, .semibold, relativeTo: .caption)

    // On-notch text — Figtree, sized for the dark band.
    static let notchTitle = sans(12, .semibold, relativeTo: .caption)
    static let notchBody = sans(13, .medium, relativeTo: .caption)
    static let notchCaption = sans(10.5, .semibold, relativeTo: .caption2)

    static let mono = Font.system(size: 12.5, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
}

// MARK: - Warm ground

/// The app's ground: a cream base gradient washed with three soft, blurred
/// accent "blooms" (the design's floating blobs), rendered statically for a
/// calm, premium feel. Drop it behind the window shell with `.ignoresSafeArea()`.
struct WarmBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0xf4e8d0), Color(hex: 0xecdfc4), Color(hex: 0xe2d3b3)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    bloom(Theme.Accent.n400, 560).opacity(0.42)
                        .position(x: w * 0.06, y: h * 0.02)
                    bloom(Theme.Sage.n400, 480).opacity(0.4)
                        .position(x: w * 0.98, y: h * 0.20)
                    bloom(Theme.Accent.n300, 440).opacity(0.4)
                        .position(x: w * 0.55, y: h * 1.02)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func bloom(_ color: Color, _ size: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .blur(radius: 72)
    }
}

// MARK: - Surface chrome (one place, applied everywhere)

extension View {
    /// The canonical **frosted-glass** card chrome: an ultra-thin material base
    /// tinted warm-white, ringed by a bright hairline with a top sheen, lifted by
    /// a soft warm shadow. This is the Organic system's primary surface; route
    /// every card/tile through it so elevation, radius and border can't drift.
    func glassCard(
        radius: CGFloat = Theme.cardRadius,
        tintOpacity: Double = 0.40,
        shadow: Theme.Shadow = Theme.shadowCard
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(
                shape
                    .fill(Theme.glassFill.opacity(tintOpacity))
                    .background(shape.fill(.ultraThinMaterial))
            )
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.6), Color.clear],
                        startPoint: .top, endPoint: .center
                    )
                )
                .blendMode(.softLight)
                .allowsHitTesting(false)
            )
            .overlay(shape.strokeBorder(Theme.glassBorderColor, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }

    /// A lighter, flatter glass for nested tiles that sit *inside* a `glassCard`
    /// (no drop shadow — just a tinted, hairline-ringed inset panel).
    func glassTile(radius: CGFloat = 16, tintOpacity: Double = 0.28) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(
                shape
                    .fill(Theme.glassFill.opacity(tintOpacity))
                    .background(shape.fill(.ultraThinMaterial))
            )
            .overlay(shape.strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
            .clipShape(shape)
    }

    /// The big window shell: a deeply-frosted panel that floats over
    /// `WarmBackground`, with the heaviest lift in the system.
    func glassPanel(radius: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(
                shape
                    .fill(Theme.Neutral.n100.opacity(0.5))
                    .background(shape.fill(.regularMaterial))
            )
            .overlay(shape.strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
            .clipShape(shape)
            .shadow(color: Theme.shadowPanel.color, radius: Theme.shadowPanel.radius, x: 0, y: Theme.shadowPanel.y)
    }

    /// Back-compat alias — the old opaque `.card()` chrome now routes through the
    /// glass card so every existing call-site inherits the Organic surface.
    func card(radius: CGFloat = Theme.cardRadius, shadow: Theme.Shadow = Theme.shadowCard) -> some View {
        glassCard(radius: radius, shadow: shadow)
    }
}
