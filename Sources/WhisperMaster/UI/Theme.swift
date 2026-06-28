import SwiftUI

/// The Whisper Master design system — "Daylight": a warm, light, editorial
/// treatment. Paper-cream ground, ink text set in Optima, and a deepened
/// vermillion accent from the app icon spent sparingly. Calm and premium rather
/// than another dark dashboard.
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
    static let canvasNSColor = NSColor.white
}

/// Type system. Display + body are Avenir Next (ships with macOS — no bundling);
/// the utility face is SF Mono for keycaps, versions, and data readouts.
enum Typography {
    /// The UI sans (Avenir Next) at an explicit weight.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Avenir Next", size: size).weight(weight)
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
