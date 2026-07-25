import AppKit
import SwiftUI

// MARK: - Hex helpers

extension Color {
    /// Build a Color from a 24-bit RGB hex, e.g. `Color(hex: 0xff6a3d)`.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }

    /// A token that resolves against the *view's* appearance at render time.
    ///
    /// This is the mechanism the whole dual-mode system rests on: tokens stay
    /// plain `static let Color`, so every call site (`Theme.textPrimary`, …)
    /// keeps working untouched and simply renders the right value for whichever
    /// appearance the window is in.
    static func dynamic(light: UInt32, dark: UInt32, alpha: Double = 1) -> Color {
        dynamic(light: light, lightAlpha: alpha, dark: dark, darkAlpha: alpha)
    }

    /// As `dynamic(light:dark:)`, but with a different alpha per mode — needed
    /// for the hairlines and glass tints, which are *black*-alpha over paper and
    /// *white*-alpha over ink, at different strengths.
    static func dynamic(light: UInt32, lightAlpha: Double, dark: UInt32, darkAlpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(
                hex: isDark ? dark : light,
                alpha: CGFloat(isDark ? darkAlpha : lightAlpha)
            )
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }

    /// AppKit twin of `Color.dynamic` for window/titlebar backgrounds.
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

// MARK: - Appearance preference

/// How the app picks its appearance. `system` follows the macOS setting; the
/// other two pin it. Applied once, app-wide, by setting `NSApp.appearance`.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon.stars"
        }
    }

    /// `nil` means "inherit the system appearance".
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The Whisper Master design system — **"Recording room at night"**, in two
/// moods.
///
/// Warm human speech going into a cool private machine: that contrast is the
/// product argument, and it is what the palette encodes. Dark mode is the
/// canonical form (ink ground, bone text); light mode is the same room with the
/// lights on (cool paper ground, slate ink) — *not* a different brand. Both run
/// the same two accents, the same geometry, the same glass.
///
/// The accent meanings are load-bearing and never swap:
///   - **ember** → the user. Voice, live state, anything in progress.
///   - **signal** → the machine. On-device work, settled output, data, success.
///
/// Each accent has two forms, because the vivid hues are unreadable on a light
/// ground (`ember` is 2.6:1 on paper): `accent`/`accent2` are the *ground-safe*
/// text-and-icon colours that deepen in light mode, while `accentFill`/
/// `accent2Fill` are the vivid brand hues used as fills, paired with their own
/// near-black on-colours. See `docs/07-design-system.md`.
enum Theme {
    // MARK: Ground ramp — ink (dark) / paper (light)

    static let ink = Color(hex: 0x07090e)
    static let ink800 = Color(hex: 0x0b0f17)
    static let ink700 = Color(hex: 0x101623)
    static let ink600 = Color(hex: 0x18202f)

    static let paper = Color(hex: 0xe9edf4)
    static let paper200 = Color(hex: 0xe1e6ef)
    static let paper300 = Color(hex: 0xd7dde8)

    /// The window ground. Light mode sits a step *below* white on purpose —
    /// the glass cards are near-white, so the ground has to be darker than they
    /// are or nothing lifts off it.
    static let canvas = Color.dynamic(light: 0xe9edf4, dark: 0x07090e)
    static let canvasTop = Color.dynamic(light: 0xf0f3f8, dark: 0x0b0f17)
    /// Raised, opaque-ish tiles.
    static let surface = Color.dynamic(light: 0xf4f6fa, dark: 0x101623)
    static let surfaceSunken = Color.dynamic(light: 0xdfe4ee, dark: 0x0b0f17)
    /// The translucent band behind the selected sidebar item.
    static let selection = Color.dynamic(light: 0xffffff, lightAlpha: 0.75, dark: 0xffffff, darkAlpha: 0.08)

    // MARK: Ink (text). Never pure white, never pure black — both are tinted.

    /// Dark 17.4:1 · light 16.8:1.
    static let textPrimary = Color.dynamic(light: 0x10141c, dark: 0xf2efe9)
    /// Dark 10.1:1 · light 11.3:1 — secondary body copy.
    static let textSecondary = Color.dynamic(light: 0x2c3444, dark: 0xaab3c4)
    /// Dark 6.5:1 · light 6.8:1 — tertiary, labels. The floor for real copy.
    static let textTertiary = Color.dynamic(light: 0x4d5566, dark: 0x8a94a8)
    /// 3.4:1 in both modes. **Decoration and non-text only** — never body copy.
    static let textFaint = Color.dynamic(light: 0x7c8595, dark: 0x5c6577)

    static let bone = Color(hex: 0xf2efe9)
    static let hazeBright = Color(hex: 0xaab3c4)
    static let haze = Color(hex: 0x8a94a8)
    static let hazeDim = Color(hex: 0x5c6577)

    // MARK: Accents

    /// Ember — the human accent. `base` is the vivid brand hue (fills);
    /// `ink` is the deepened cut that stays readable on a light ground.
    enum Ember {
        static let base = Color(hex: 0xff6a3d)
        static let bright = Color(hex: 0xff8b64)
        static let deep = Color(hex: 0xd94a20)
        /// 5.1:1 on paper — the light-mode text/icon cut.
        static let ink = Color(hex: 0xb53812)
        /// Text placed *on* an ember fill: a near-black tint of the hue, 6.8:1.
        static let on = Color(hex: 0x1a0a04)
        static let soft = Color.dynamic(light: 0xff6a3d, lightAlpha: 0.14, dark: 0xff6a3d, darkAlpha: 0.12)
    }

    /// Signal — the machine accent.
    enum Signal {
        static let base = Color(hex: 0x6ee7df)
        static let bright = Color(hex: 0x9df3ed)
        static let deep = Color(hex: 0x3bbdb4)
        /// 6.3:1 on paper — the light-mode text/icon cut.
        static let ink = Color(hex: 0x136059)
        /// Text placed *on* a signal fill, 11.4:1.
        static let on = Color(hex: 0x04211f)
        static let soft = Color.dynamic(light: 0x17756d, lightAlpha: 0.13, dark: 0x6ee7df, darkAlpha: 0.14)
    }

    /// Ground-safe ember: text, icons, strokes. Deepens in light mode.
    static let accent = Color.dynamic(light: 0xb53812, dark: 0xff6a3d)
    /// The vivid ember hue, for fills that carry their own on-colour.
    static let accentFill = Ember.base
    /// Text/glyphs drawn *on* `accentFill`.
    static let accentOn = Ember.on
    static let accentSoft = Ember.soft
    /// Back-compat alias — the deepened accent for text/kickers.
    static let accentText = accent

    /// Ground-safe signal.
    static let accent2 = Color.dynamic(light: 0x136059, dark: 0x6ee7df)
    static let accent2Fill = Signal.base
    static let accent2On = Signal.on
    static let accent2Soft = Signal.soft

    // MARK: Status. Success is signal — a finished machine job.

    static let success = accent2
    static let successSoft = Signal.soft
    static let danger = Color.dynamic(light: 0xb3261e, dark: 0xff5f52)
    static let dangerSoft = Color.dynamic(light: 0xb3261e, lightAlpha: 0.12, dark: 0xff5f52, darkAlpha: 0.16)
    static let warning = Color.dynamic(light: 0x8a5a00, dark: 0xffc25c)
    static let warningSoft = Color.dynamic(light: 0x8a5a00, lightAlpha: 0.13, dark: 0xffc25c, darkAlpha: 0.16)

    // MARK: Lines + surfaces — translucent, never an opaque grey slab.

    static let line = Color.dynamic(light: 0x000000, lightAlpha: 0.10, dark: 0xffffff, darkAlpha: 0.09)
    static let lineSoft = Color.dynamic(light: 0x000000, lightAlpha: 0.06, dark: 0xffffff, darkAlpha: 0.055)
    static let surfaceGlass = Color.dynamic(light: 0xffffff, lightAlpha: 0.62, dark: 0xffffff, darkAlpha: 0.035)
    static let surfaceGlass2 = Color.dynamic(light: 0xffffff, lightAlpha: 0.85, dark: 0xffffff, darkAlpha: 0.06)
    /// The 1px inset top highlight that makes a card read as a solid object.
    static let topHighlight = Color.dynamic(light: 0xffffff, lightAlpha: 0.85, dark: 0xffffff, darkAlpha: 0.07)

    static let stroke = line
    static let strokeStrong = Color.dynamic(light: 0x000000, lightAlpha: 0.16, dark: 0xffffff, darkAlpha: 0.16)

    /// The tint laid over the blur in a glass card.
    static let glassFill = surfaceGlass
    /// The hairline that rings a glass card.
    static let glassBorderColor = line

    // MARK: Geometry. Pills are fully round; cards are 16.

    static let cardRadius: CGFloat = 16
    static let panelRadius: CGFloat = 18
    /// Input wells and other non-button controls. Buttons use `Capsule`.
    static let controlRadius: CGFloat = 12
    static let pillRadius: CGFloat = 999
    static let chipRadius: CGFloat = 999

    // MARK: Spacing scale (prefer these over raw numbers)

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Elevation — deep, soft, wide.

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    static let shadowCard = Shadow(
        color: .dynamic(light: 0x1a2233, lightAlpha: 0.13, dark: 0x000000, darkAlpha: 0.72),
        radius: 30, x: 0, y: 16
    )
    static let shadowRaised = Shadow(
        color: .dynamic(light: 0x1a2233, lightAlpha: 0.14, dark: 0x000000, darkAlpha: 0.6),
        radius: 10, x: 0, y: 4
    )
    static let shadowPanel = Shadow(
        color: .dynamic(light: 0x1a2233, lightAlpha: 0.20, dark: 0x000000, darkAlpha: 0.85),
        radius: 60, x: 0, y: 30
    )

    /// Selection and active states are an accent-tinted **glow**, never a
    /// brighter border.
    static func shadowGlow(_ color: Color) -> Shadow {
        Shadow(color: color.opacity(0.42), radius: 40, x: 0, y: 16)
    }

    // MARK: Motion — hard decelerate, no overshoot. Nothing bounces.

    enum Motion {
        /// The house curve, `cubic-bezier(0.16, 1, 0.3, 1)`: fast out, long soft
        /// settle. Springs are deliberately *not* used — they overshoot, and
        /// this system never does.
        static let settle = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.42)
        static let quick = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.25)
        static let fade = Animation.easeOut(duration: 0.2)

        static let toggle = quick
        static let appear = settle
        static let retract = quick
        static let step = fade

        /// Returns `base`, or `nil` when Reduce Motion is on.
        static func respecting(_ reduceMotion: Bool, _ base: Animation?) -> Animation? {
            reduceMotion ? nil : base
        }
    }

    // MARK: The notch (always-dark) sub-palette
    /// The pill sits on the physical black bezel, so it ignores the light/dark
    /// setting entirely and is always ink. This is also the surface where the
    /// old and new systems already agreed.
    enum Notch {
        static let surface = Color(hex: 0x07090e)
        static let text = Color(hex: 0xf2efe9)
        static let textSecondary = Color(hex: 0xaab3c4)
        static let textTertiary = Color(hex: 0x8a94a8)
        static let hairline = Color.white.opacity(0.09)
        static let glassSheen = LinearGradient(
            colors: [Color.white.opacity(0.07), Color.clear],
            startPoint: .top, endPoint: .bottom
        )
        static let glassBorder = Color.white.opacity(0.09)
        static let success = Signal.base
        static let danger = Color(hex: 0xff5f52)
        static let warning = Color(hex: 0xffc25c)
        /// The live listening wave is **ember** — it is your voice.
        static let waveGradient = Gradient(colors: [Ember.base, Ember.bright])
        static let accent = Ember.base
    }

    // MARK: Legacy tonal ramps
    /// Kept so the handful of remaining call sites compile; remapped onto the
    /// ink/paper ladder rather than the retired cream palette. Prefer the
    /// semantic tokens above in new code.

    enum Accent {
        static let n100 = Color(hex: 0xffe8df)
        static let n200 = Color(hex: 0xffd0bf)
        static let n300 = Color(hex: 0xffb499)
        static let n400 = Color(hex: 0xff8b64)
        static let n500 = Color(hex: 0xff6a3d)
        static let n600 = Color(hex: 0xd94a20)
        static let n700 = Color(hex: 0xc03d15)
        static let n800 = Color(hex: 0x8a2b0e)
        static let n900 = Color(hex: 0x1a0a04)
    }

    enum Sage {
        static let n100 = Color(hex: 0xe2faf7)
        static let n200 = Color(hex: 0xc4f3ee)
        static let n300 = Color(hex: 0x9df3ed)
        static let n400 = Color(hex: 0x6ee7df)
        static let n500 = Color(hex: 0x3bbdb4)
        static let n600 = Color(hex: 0x17756d)
        static let n700 = Color(hex: 0x115a54)
        static let n800 = Color(hex: 0x0a3b37)
        static let n900 = Color(hex: 0x04211f)
    }

    enum Neutral {
        static let n100 = Color(hex: 0xf2f4f8)
        static let n200 = Color(hex: 0xe9ecf2)
        static let n300 = Color(hex: 0xdfe3ec)
        static let n400 = Color(hex: 0xaab3c4)
        static let n500 = Color(hex: 0x8a94a8)
        static let n600 = Color(hex: 0x5c6577)
        static let n700 = Color(hex: 0x4d5566)
        static let n800 = Color(hex: 0x18202f)
        static let n900 = Color(hex: 0x07090e)
    }

    // MARK: Ground wash

    static let canvasGradient = LinearGradient(
        colors: [canvasTop, canvas],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// AppKit ground colour for window backgrounds / titlebars.
    static let canvasNSColor = NSColor.dynamic(light: 0xf2f4f8, dark: 0x07090e)
}

// MARK: - Fonts

/// Resolves the bundled brand faces, registering them once and falling back to
/// the closest system faces if a file is missing (so the app never renders
/// blank text). Registration happens at launch via `registerAll()`.
enum BrandFont {
    /// Display face. Bricolage Grotesque, instanced from the variable font at
    /// optical size 24 with a corrected name table (upstream ships a mangled
    /// `Bricolage Grotesque 96pt ExtraBold` family that never resolves).
    static let heading = "Bricolage Grotesque"
    static let body = "Instrument Sans"

    /// Register every `.ttf` in the resource bundle's `Fonts/` folder with Core
    /// Text (process-scoped). Idempotent; safe to call at launch.
    static func registerAll() {
        guard let bundle = resourceBundle else { return }
        let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static var hasHeading: Bool { NSFont(name: heading, size: 12) != nil }
    static var hasBody: Bool { NSFont(name: body, size: 12) != nil }

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

/// Type system. Display/titles are **Bricolage Grotesque** (heavy, tightly
/// tracked); body/UI text is **Instrument Sans**; the utility face is SF Mono
/// for labels, keycaps and data readouts — the platform-native instrument face,
/// an accepted substitution for JetBrains Mono.
///
/// Every named token carries a `relativeTo:` text style so the UI honours the
/// system Dynamic Type setting. Display type also needs **tracking** — untracked
/// display type is the fastest way to lose the look — so pair the display
/// tokens with `.tracked(Typography.trackingFor(size))` or the `.displayTitle()`
/// helpers below.
enum Typography {
    /// The UI/body sans at an explicit weight, scaling relative to a Dynamic
    /// Type text style. Falls back to the system sans.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        if BrandFont.hasBody {
            return .custom(BrandFont.body, size: size, relativeTo: textStyle).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    /// The display/heading face. Falls back to a bold system face.
    static func heading(_ size: CGFloat, _ weight: Font.Weight = .bold, relativeTo textStyle: Font.TextStyle = .title) -> Font {
        if BrandFont.hasHeading {
            return .custom(BrandFont.heading, size: size, relativeTo: textStyle).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    /// The house tracking ramp: roughly `-0.045em` at section size easing to
    /// `-0.035em` at card size.
    static func trackingFor(_ size: CGFloat) -> CGFloat {
        -0.042 * size
    }

    // Display / headings — Bricolage Grotesque.
    static let largeTitle = heading(34, .heavy, relativeTo: .largeTitle)
    static let title = heading(22, .bold, relativeTo: .title)
    static let headline = heading(16, .semibold, relativeTo: .headline)
    /// Big KPI / dashboard numbers.
    static let metric = heading(32, .heavy, relativeTo: .largeTitle)

    static let largeTitleTracking = trackingFor(34)
    static let titleTracking = trackingFor(22)
    static let headlineTracking = trackingFor(16)
    static let metricTracking = trackingFor(32)

    // Body / UI — Instrument Sans.
    static let body = sans(14, .regular, relativeTo: .body)
    static let bodyMedium = sans(14, .medium, relativeTo: .body)
    static let subheadline = sans(13, .regular, relativeTo: .subheadline)
    static let caption = sans(12, .medium, relativeTo: .caption)
    static let kicker = sans(11, .semibold, relativeTo: .caption2)
    static let label = sans(12, .semibold, relativeTo: .caption)

    // On-notch text.
    static let notchTitle = sans(12, .semibold, relativeTo: .caption)
    static let notchBody = sans(13, .medium, relativeTo: .caption)
    static let notchCaption = sans(10.5, .semibold, relativeTo: .caption2)

    /// The instrument voice: mono, uppercase, widely tracked. Apply with
    /// `.monoLabel()` so the casing and tracking travel with the font.
    static let mono = Font.system(size: 12.5, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let monoLabel = Font.system(size: 11, weight: .medium, design: .monospaced)
}

extension View {
    /// Tighten display type. Untracked display type loses the system.
    func tracked(_ amount: CGFloat) -> some View { tracking(amount) }

    /// The mono instrument label: uppercase, `0.2em` tracking, tertiary ink.
    /// The single highest signature-per-effort element in the system.
    func monoLabel() -> some View {
        font(Typography.monoLabel)
            .tracking(2.2)
            .textCase(.uppercase)
    }
}

// MARK: - Ground

/// The app's ground: the base gradient washed with soft, blurred accent
/// "blooms" — ember and signal, the only two hues in the system. Static, for a
/// calm ground rather than an animated one. Drop it behind the window shell.
struct AuroraBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Light mode keeps the blooms very faint — at dark-mode strength they read
    /// as a tie-dyed wash rather than a calm ground.
    private var bloomOpacity: Double { colorScheme == .dark ? 0.30 : 0.09 }

    var body: some View {
        ZStack {
            Theme.canvasGradient
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    bloom(Theme.Ember.base, 560).opacity(bloomOpacity)
                        .position(x: w * 0.06, y: h * 0.02)
                    bloom(Theme.Signal.base, 480).opacity(bloomOpacity * 0.9)
                        .position(x: w * 0.98, y: h * 0.20)
                    bloom(Theme.Ember.deep, 440).opacity(bloomOpacity * 0.8)
                        .position(x: w * 0.55, y: h * 1.02)
                }
            }
            // Stops large flat fields banding on wide-gamut displays — a real
            // problem on this app's target hardware, worst in dark mode.
            GrainOverlay(opacity: colorScheme == .dark ? 0.35 : 0.12)
        }
        .ignoresSafeArea()
    }

    private func bloom(_ color: Color, _ size: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .blur(radius: 80)
    }
}

/// Back-compat alias for the retired cream ground.
typealias WarmBackground = AuroraBackground

/// A tiled fractal-noise wash, the Swift equivalent of the web build's SVG
/// grain. Purely decorative and hidden from assistive tech.
struct GrainOverlay: View {
    var opacity: Double = 0.35

    var body: some View {
        Group {
            if let image = Self.tile {
                Image(nsImage: image)
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One 128×128 monochrome noise tile, built once per process.
    private static let tile: NSImage? = {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9e37_79b9_7f4a_7c15
        for index in stride(from: 0, to: pixels.count, by: 4) {
            // xorshift — deterministic, so the grain never shimmers between runs.
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            let value = UInt8(truncatingIfNeeded: seed >> 33)
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
            pixels[index + 3] = 255
        }
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }()
}

// MARK: - The mark

/// The Whisper Master mark: a mic-level meter. Bars 1–3 are ember (your voice),
/// the trailing bar is signal (what the machine wrote). The ratios are fixed.
struct LevelMark: View {
    var height: CGFloat = 17

    private let ratios: [CGFloat] = [0.44, 1.0, 0.66, 0.28]

    var body: some View {
        HStack(alignment: .center, spacing: height * 0.118) {
            ForEach(Array(ratios.enumerated()), id: \.offset) { index, ratio in
                Capsule()
                    .fill(index == 3 ? Theme.Signal.base : Theme.Ember.base)
                    .frame(width: height * 0.118, height: height * ratio)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The record dot: a small ember circle that breathes an expanding ring while
/// live. Never scales — the ring grows, the dot does not.
struct RecordDot: View {
    var isLive: Bool = false
    var size: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(Theme.Ember.base)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(Theme.Ember.base.opacity(breathing ? 0 : 0.55), lineWidth: 1)
                    .scaleEffect(breathing ? 2.8 : 1)
            )
            .onAppear {
                guard isLive, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) {
                    breathing = true
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Surface chrome (one place, applied everywhere)

extension View {
    /// The canonical **glass** card: a material blur tinted per mode, ringed by
    /// a hairline, with a 1px inset top highlight and a deep soft shadow.
    ///
    /// Three things make it read as a physical object — the vertical gradient,
    /// the top light-catch, and the wide soft shadow. Drop any one and it
    /// flattens. Honours Reduce Transparency with an opaque fallback.
    func glassCard(
        radius: CGFloat = Theme.cardRadius,
        tintOpacity: Double = 1,
        shadow: Theme.Shadow = Theme.shadowCard,
        glow: Color? = nil
    ) -> some View {
        modifier(GlassSurface(radius: radius, tintScale: tintOpacity, shadow: glow.map(Theme.shadowGlow) ?? shadow, highlight: true))
    }

    /// A flatter glass for tiles nested *inside* a `glassCard` — no drop shadow.
    func glassTile(radius: CGFloat = 12, tintOpacity: Double = 0.7) -> some View {
        modifier(GlassSurface(radius: radius, tintScale: tintOpacity, shadow: nil, highlight: false))
    }

    /// The big window shell: the most deeply frosted panel in the system, with
    /// the heaviest lift.
    func glassPanel(radius: CGFloat = Theme.panelRadius) -> some View {
        modifier(GlassSurface(radius: radius, tintScale: 1.1, shadow: Theme.shadowPanel, highlight: true, heavy: true))
    }

    /// Back-compat alias — the old opaque `.card()` chrome routes through glass.
    func card(radius: CGFloat = Theme.cardRadius, shadow: Theme.Shadow = Theme.shadowCard) -> some View {
        glassCard(radius: radius, shadow: shadow)
    }
}

/// The one place the glass recipe lives, so elevation, radius and border can't
/// drift between surfaces.
private struct GlassSurface: ViewModifier {
    let radius: CGFloat
    let tintScale: Double
    let shadow: Theme.Shadow?
    let highlight: Bool
    var heavy: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    /// The vertical gradient: lighter at the top, so the surface catches light
    /// like a real object.
    private var tint: LinearGradient {
        let isDark = colorScheme == .dark
        let top = isDark ? Color(hex: 0x101623) : Color.white
        let bottom = isDark ? Color(hex: 0x0b0f17) : Color.white
        let topAlpha = (isDark ? 0.72 : 0.86) * tintScale
        let bottomAlpha = (isDark ? 0.60 : 0.66) * tintScale
        return LinearGradient(
            colors: [top.opacity(min(topAlpha, 1)), bottom.opacity(min(bottomAlpha, 1))],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// Reduce Transparency gets a genuinely opaque surface, not a thinner blur.
    private var opaqueFallback: Color {
        colorScheme == .dark ? Color(hex: 0x101623) : Color(hex: 0xeef1f6)
    }

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(opaqueFallback)
                } else {
                    shape.fill(tint)
                        .background(shape.fill(heavy ? .regularMaterial : .ultraThinMaterial))
                }
            }
            .overlay {
                if highlight {
                    // The 1px light catch along the top edge — do not omit, it
                    // carries the solidity.
                    shape
                        .strokeBorder(Theme.topHighlight, lineWidth: 1)
                        .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
                        .allowsHitTesting(false)
                }
            }
            .overlay(shape.strokeBorder(Theme.line, lineWidth: 1))
            .clipShape(shape)
            .modifier(OptionalShadow(shadow: shadow))
    }
}

private struct OptionalShadow: ViewModifier {
    let shadow: Theme.Shadow?

    func body(content: Content) -> some View {
        if let shadow {
            content.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
        } else {
            content
        }
    }
}
