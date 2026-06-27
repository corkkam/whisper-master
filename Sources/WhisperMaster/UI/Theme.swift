import SwiftUI

/// The Whisper Master design system — "Midnight": the dark, glassmorphic
/// treatment carried over from the whispermaster.com landing page. A near-black
/// indigo-tinted ground, frosted translucent surfaces, an electric-indigo
/// accent (#6366F1) with violet/cyan glows, and white-tinted hairlines. Cool,
/// premium, product-forward.
enum Theme {
    // MARK: Ground + surfaces (near-black base, frosted glass overlays)
    /// Base-900 — the main near-black ground (#0A0A0F).
    static let canvas = Color(red: 0.039, green: 0.039, blue: 0.059)
    /// A touch lighter at the top for the ambient wash (#12121C-ish).
    static let canvasTop = Color(red: 0.075, green: 0.075, blue: 0.110)
    /// Frosted glass tile: white at low opacity over the dark ground.
    static let surface = Color.white.opacity(0.05)
    /// More recessed glass — toggle-off tracks, icon buttons, pressed ghost.
    static let surfaceSunken = Color.white.opacity(0.028)
    /// Accent-tinted band used for the selected sidebar item.
    static let selection = Color(red: 0.388, green: 0.400, blue: 0.945).opacity(0.16)

    // MARK: Ink (white at descending opacity, matching the landing scale)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.64)
    static let textTertiary = Color.white.opacity(0.45)

    // MARK: Brand / status (electric indigo, glows for depth)
    /// Primary accent — Electric Indigo (#6366F1).
    static let accent = Color(red: 0.388, green: 0.400, blue: 0.945)
    static let accentSoft = Color(red: 0.388, green: 0.400, blue: 0.945).opacity(0.15)
    /// Lighter indigo (#A5B4FC) for the head of the accent gradient.
    static let accentLight = Color(red: 0.647, green: 0.706, blue: 0.988)
    /// Cyan glow (#22D3EE) for the tail of the accent gradient.
    static let cyan = Color(red: 0.133, green: 0.827, blue: 0.933)
    /// Violet glow (#8B5CF6) for ambient depth.
    static let violet = Color(red: 0.545, green: 0.361, blue: 0.965)
    static let success = Color(red: 0.220, green: 0.820, blue: 0.560)
    static let danger = Color(red: 0.960, green: 0.380, blue: 0.450)

    // MARK: Lines (white-tinted hairlines)
    static let stroke = Color.white.opacity(0.08)
    static let strokeStrong = Color.white.opacity(0.16)

    // MARK: Geometry (softer rounding, matching rounded-2xl/-xl)
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 10

    // MARK: Ground wash (subtle indigo-black, top to bottom)
    static let canvasGradient = LinearGradient(
        colors: [canvasTop, canvas],
        startPoint: .top,
        endPoint: .bottom
    )

    /// 110°-ish accent sweep (#A5B4FC → #6366F1 → #22D3EE) — the landing's
    /// `.accent-gradient-text`. Used for the wordmark and the dictation thread.
    static let accentGradient = LinearGradient(
        colors: [accentLight, accent, cyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Soft indigo glow color for `shadow-glow` (rgba(99,102,241,0.45)).
    static let glow = Color(red: 0.388, green: 0.400, blue: 0.945).opacity(0.45)

    /// AppKit ground color for window backgrounds / titlebars.
    static let canvasNSColor = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.059, alpha: 1)
}

/// Type system. The landing page is set in Inter; on macOS we use the native
/// SF Pro system face (no bundling, visually near-identical at UI sizes). The
/// utility face stays SF Mono for keycaps, versions, and data readouts.
enum Typography {
    /// The UI sans (system SF Pro) at an explicit weight.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static let largeTitle = sans(31, .bold)
    static let title = sans(21, .bold)
    static let headline = sans(15.5, .semibold)
    static let body = sans(14, .regular)
    static let bodyMedium = sans(14, .medium)
    static let subheadline = sans(13, .regular)
    static let caption = sans(12, .medium)
    static let kicker = sans(11.5, .bold)
    static let label = sans(12, .semibold)
    static let mono = Font.system(size: 12.5, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
}
