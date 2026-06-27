import SwiftUI

/// The Whisper Master design system — "Daylight": a warm, light, editorial
/// treatment. Paper-cream ground, ink text set in Optima, and a deepened
/// vermillion accent from the app icon spent sparingly. Calm and premium rather
/// than another dark dashboard.
enum Theme {
    // MARK: Ground + surfaces (warm paper, not pure white)
    static let canvas = Color(red: 0.957, green: 0.933, blue: 0.882)
    static let canvasTop = Color(red: 0.965, green: 0.945, blue: 0.898)
    /// Slightly lifted paper for the few boxed elements (tiles, the words field).
    static let surface = Color(red: 0.984, green: 0.969, blue: 0.937)
    static let surfaceSunken = Color(red: 0.925, green: 0.902, blue: 0.851)
    /// Warm sand band used for the selected sidebar item.
    static let selection = Color(red: 0.890, green: 0.851, blue: 0.776)

    // MARK: Ink
    static let textPrimary = Color(red: 0.129, green: 0.110, blue: 0.082)
    static let textSecondary = Color(red: 0.486, green: 0.447, blue: 0.392)
    static let textTertiary = Color(red: 0.655, green: 0.620, blue: 0.557)

    // MARK: Brand / status (deepened for contrast on a light ground)
    static let accent = Color(red: 0.753, green: 0.220, blue: 0.102)
    static let accentSoft = Color(red: 0.753, green: 0.220, blue: 0.102).opacity(0.12)
    static let success = Color(red: 0.235, green: 0.478, blue: 0.306)
    static let danger = Color(red: 0.753, green: 0.220, blue: 0.102)

    // MARK: Lines (ink-tinted, not pure black)
    static let stroke = Color(red: 0.129, green: 0.110, blue: 0.082).opacity(0.12)
    static let strokeStrong = Color(red: 0.129, green: 0.110, blue: 0.082).opacity(0.20)

    // MARK: Geometry
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 9

    // MARK: Ground wash (very subtle warmth, top to bottom)
    static let canvasGradient = LinearGradient(
        colors: [canvasTop, canvas],
        startPoint: .top,
        endPoint: .bottom
    )
    /// AppKit ground color for window backgrounds / titlebars.
    static let canvasNSColor = NSColor(srgbRed: 0.957, green: 0.933, blue: 0.882, alpha: 1)
}

/// Type system. Display + body are Optima (ships with macOS — no bundling); the
/// utility face is SF Mono for keycaps, versions, and data readouts.
enum Typography {
    /// Optima at an explicit weight. Optima runs small, so sizes here are tuned
    /// a touch larger than an SF-based scale would be.
    static func optima(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Optima", size: size).weight(weight)
    }

    static let largeTitle = optima(33, .bold)
    static let title = optima(22, .bold)
    static let headline = optima(16.5, .bold)
    static let body = optima(15)
    static let bodyMedium = optima(15, .medium)
    static let subheadline = optima(13.5)
    static let caption = optima(12.5, .medium)
    static let kicker = optima(12, .bold)
    static let label = optima(12.5, .semibold)
    static let mono = Font.system(size: 12.5, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
}
