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
}

/// The Whisper Master design system — **"Recording room, lights on"**.
///
/// Warm human speech going into a cool private machine: that contrast is the
/// product argument, and it is what the palette encodes. The app is
/// **light-only** — a cool paper ground under slate ink. There is no dark mode
/// and no appearance preference: `NSApp.appearance` is pinned to `.aqua` at
/// launch (`AppDelegate.applicationDidFinishLaunching`) so a Mac running in dark
/// mode can't leak system-dark chrome into our windows.
///
/// The one always-ink surface is the notch band, and it is **not** a dark mode:
/// it draws on the physical black bezel, so it has its own fixed sub-palette
/// (`Theme.Notch`, reached through `.onDarkSurface()`). Nothing else in the app
/// varies by appearance, so every token below is a plain constant.
///
/// The accent meanings are load-bearing and never swap:
///   - **ember** → the user. Voice, live state, anything in progress.
///   - **signal** → the machine. On-device work, settled output, data, success.
///
/// Each accent has two forms, because the vivid hues are unreadable on a light
/// ground (`ember` is 2.6:1 on paper): `accent`/`accent2` are the *ground-safe*
/// text-and-icon colours, while `accentFill`/`accent2Fill` are the vivid brand
/// hues used as fills, paired with their own near-black on-colours. See
/// `docs/07-design-system.md`.
enum Theme {
    // MARK: Ground ramp — paper

    static let paper = Color(hex: 0xe9edf4)
    static let paper200 = Color(hex: 0xe1e6ef)
    static let paper300 = Color(hex: 0xd7dde8)

    /// The window ground. It sits a step *below* white on purpose — the glass
    /// cards are near-white, so the ground has to be darker than they are or
    /// nothing lifts off it.
    static let canvas = Color(hex: 0xe9edf4)
    static let canvasTop = Color(hex: 0xf0f3f8)
    /// Raised, opaque-ish tiles.
    static let surface = Color(hex: 0xf4f6fa)
    static let surfaceSunken = Color(hex: 0xdfe4ee)
    /// The translucent band behind the selected sidebar item.
    static let selection = Color(hex: 0xffffff, alpha: 0.75)

    // MARK: Ink (text). Never pure black — it's tinted.

    /// 16.8:1 on the paper ground.
    static let textPrimary = Color(hex: 0x10141c)
    /// 11.3:1 — secondary body copy.
    static let textSecondary = Color(hex: 0x2c3444)
    /// 6.8:1 — tertiary, labels. The floor for real copy.
    static let textTertiary = Color(hex: 0x4d5566)
    /// 3.4:1. **Decoration and non-text only** — never body copy.
    static let textFaint = Color(hex: 0x7c8595)

    // MARK: Accents

    /// Ember — the human accent. `base` is the vivid brand hue (fills);
    /// `ink` is the deepened cut that stays readable on a light ground.
    enum Ember {
        static let base = Color(hex: 0xff6a3d)
        static let bright = Color(hex: 0xff8b64)
        static let deep = Color(hex: 0xd94a20)
        /// 5.1:1 on paper — the text/icon cut.
        static let ink = Color(hex: 0xb53812)
        /// Text placed *on* an ember fill: a near-black tint of the hue, 6.8:1.
        static let on = Color(hex: 0x1a0a04)
        static let soft = Color(hex: 0xff6a3d, alpha: 0.14)
    }

    /// Signal — the machine accent.
    enum Signal {
        static let base = Color(hex: 0x6ee7df)
        static let bright = Color(hex: 0x9df3ed)
        static let deep = Color(hex: 0x3bbdb4)
        /// 6.3:1 on paper — the text/icon cut.
        static let ink = Color(hex: 0x136059)
        /// Text placed *on* a signal fill, 11.4:1.
        static let on = Color(hex: 0x04211f)
        static let soft = Color(hex: 0x17756d, alpha: 0.13)
    }

    /// Ground-safe ember: text, icons, strokes — the deepened cut that stays
    /// readable on paper.
    static let accent = Color(hex: 0xb53812)
    /// The vivid ember hue, for fills that carry their own on-colour.
    static let accentFill = Ember.base
    /// Text/glyphs drawn *on* `accentFill`.
    static let accentOn = Ember.on
    static let accentSoft = Ember.soft
    /// Back-compat alias — the deepened accent for text/kickers.
    static let accentText = accent

    /// Ground-safe signal.
    static let accent2 = Color(hex: 0x136059)
    static let accent2Fill = Signal.base
    static let accent2On = Signal.on
    static let accent2Soft = Signal.soft

    // MARK: Status. Success is signal — a finished machine job.

    static let success = accent2
    static let successSoft = Signal.soft
    static let danger = Color(hex: 0xb3261e)
    static let dangerSoft = Color(hex: 0xb3261e, alpha: 0.12)
    static let warning = Color(hex: 0x8a5a00)
    static let warningSoft = Color(hex: 0x8a5a00, alpha: 0.13)

    // MARK: Lines + surfaces — translucent, never an opaque grey slab.

    static let line = Color(hex: 0x000000, alpha: 0.10)
    static let lineSoft = Color(hex: 0x000000, alpha: 0.06)
    static let surfaceGlass = Color(hex: 0xffffff, alpha: 0.62)
    static let surfaceGlass2 = Color(hex: 0xffffff, alpha: 0.85)
    /// The 1px inset top highlight that makes a card read as a solid object.
    static let topHighlight = Color(hex: 0xffffff, alpha: 0.85)

    static let stroke = line
    static let strokeStrong = Color(hex: 0x000000, alpha: 0.16)

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

    // MARK: Interaction state layers

    /// How strongly an interactive surface responds to hover, focus and press.
    ///
    /// The spec (`docs/07-design-system.md` §6) fixes hover *motion* — 2px up on
    /// the house curve — but not hover *intensity*, which is why every control
    /// used to invent its own. These are that missing half: one tint, four
    /// strengths, so a hovered row in Settings and a hovered button in the
    /// onboarding band respond by the same amount.
    ///
    /// The tint is ink over paper. The notch band, being always ink, overrides it
    /// with `Theme.Notch.stateLayerTint` via `.onDarkSurface()`.
    enum StateLayer {
        /// A whisper — "this responds".
        static let hover: Double = 0.08
        /// Keyboard focus. Stronger than hover, because it has to be findable
        /// without a pointer.
        static let focus: Double = 0.12
        /// Press feedback, at focus strength.
        static let pressed: Double = 0.12

        /// Disabled containers and content, following Material Design 3's split:
        /// the container barely registers, the label stays just readable enough
        /// to identify. Content at 38% of `textPrimary` clears 3:1 — above the
        /// non-text floor, deliberately below the body-copy floor, because
        /// disabled text is not copy the user has to read.
        static let disabledContainer: Double = 0.12
        static let disabledContent: Double = 0.38

        /// The hover lift, per §6: **2px up, never a scale.** Scaling a control on
        /// hover is the bouncy, overshooting idiom this system rejects.
        static let lift: CGFloat = -2

        /// The overlay colour every state layer is drawn in.
        static let tint = Color(hex: 0x10141c)
    }

    // MARK: Elevation — deep, soft, wide.

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    static let shadowCard = Shadow(
        color: Color(hex: 0x1a2233, alpha: 0.13),
        radius: 30, x: 0, y: 16
    )
    static let shadowRaised = Shadow(
        color: Color(hex: 0x1a2233, alpha: 0.14),
        radius: 10, x: 0, y: 4
    )
    static let shadowPanel = Shadow(
        color: Color(hex: 0x1a2233, alpha: 0.20),
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

    // MARK: Sticky notes

    /// The sticky-note tints for the notes canvas.
    ///
    /// Deliberately **desaturated paper**, not the highlighter yellows a real
    /// sticky pad uses: the ground is already paper, the two accents are spoken for
    /// (§1 — ember is the user, signal is the machine), and five saturated squares
    /// would shout down every other surface in the app. Each tint is a wash the
    /// primary ink still clears 4.5:1 on, so a note is readable at any size without
    /// a per-tint text colour.
    ///
    /// Index order is load-bearing: `Note.colorIndex` is **stored**, so reordering
    /// this array silently recolours every existing note. Append, don't reshuffle —
    /// and keep the count at `Note.paletteSize`.
    enum Sticky {
        static let fills: [Color] = [
            Color(hex: 0xfdf0e6), // warm sand — ember's neighbour, no ember
            Color(hex: 0xe8f4f2), // pale signal
            Color(hex: 0xf0eef8), // cool lilac
            Color(hex: 0xfaf3dc), // faint straw
            Color(hex: 0xecf1f7), // paper blue
        ]

        /// The hairline that rings a sticky, per tint — the fill darkened rather
        /// than a shared grey, so the edge belongs to the paper it's on.
        static let strokes: [Color] = [
            Color(hex: 0xe0c9b4),
            Color(hex: 0xbfd8d4),
            Color(hex: 0xd0cbe4),
            Color(hex: 0xdfd3a8),
            Color(hex: 0xc9d6e6),
        ]

        /// Clamped lookup — a note carrying an index from a future, larger palette
        /// (pulled in by a sync from a newer build) renders in a real colour rather
        /// than crashing on an out-of-bounds read.
        static func fill(_ index: Int) -> Color {
            fills[((index % fills.count) + fills.count) % fills.count]
        }

        static func stroke(_ index: Int) -> Color {
            strokes[((index % strokes.count) + strokes.count) % strokes.count]
        }
    }

    // MARK: The notch (always-ink) sub-palette
    /// The pill sits on the physical black bezel, so it is always ink while the
    /// rest of the app is paper. **This is not a dark mode** — it's one surface
    /// matched to the hardware behind it, which is why it survives the app being
    /// light-only. Reached through `.onDarkSurface()`; see `UI/CLAUDE.md`.
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

        /// Control fills for buttons living on the band. The app-wide
        /// `surfaceGlass` tokens are tuned for the paper ground, which would be
        /// invisible here — this surface is always ink, because it sits on the
        /// physical bezel.
        static let controlFill = Color.white.opacity(0.06)
        static let controlFillPressed = Color.white.opacity(0.10)
        /// The band's state-layer tint: bone, since the ground is always dark.
        static let stateLayerTint = Color(hex: 0xf2efe9)

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
    static let canvasNSColor = NSColor(hex: 0xf2f4f8)
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
    /// The dictation bar's state line ("Dictating") — bold, since on the bar it is
    /// the only text and has to read at a glance from across the menu bar.
    static let notchLabel = sans(13, .bold, relativeTo: .caption)
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
    /// The blooms stay very faint on the paper ground — any stronger and they
    /// read as a tie-dyed wash rather than a calm ground.
    private let bloomOpacity: Double = 0.09

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
            // problem on this app's target hardware.
            GrainOverlay(opacity: 0.12)
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
    /// The canonical **glass** card: a tinted material blur, ringed by a
    /// hairline, with a 1px inset top highlight and a deep soft shadow.
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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    /// The vertical gradient: lighter at the top, so the surface catches light
    /// like a real object.
    private var tint: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(min(0.86 * tintScale, 1)),
                Color.white.opacity(min(0.66 * tintScale, 1)),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// Reduce Transparency gets a genuinely opaque surface, not a thinner blur.
    private let opaqueFallback = Color(hex: 0xeef1f6)

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
