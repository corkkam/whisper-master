import SwiftUI

/// The Whisper Master design system: a warm, professional palette drawn from the
/// app icon — charcoal and vermillion on cream. The UI is predominantly a deep
/// warm "espresso" dark with a cream-white text voice and a confident vermillion
/// accent (used as a gradient for actions and selection). Not flat grey-on-grey:
/// surfaces carry real tonal separation and a faint top highlight.
enum Theme {
    // MARK: Surfaces (warm, with genuine tonal range)
    static let canvas = Color(red: 0.078, green: 0.067, blue: 0.055)
    static let canvasTop = Color(red: 0.118, green: 0.102, blue: 0.086)
    static let surface = Color(red: 0.133, green: 0.114, blue: 0.098)
    static let surfaceElevated = Color(red: 0.172, green: 0.149, blue: 0.129)
    static let sidebar = Color(red: 0.055, green: 0.047, blue: 0.039)

    // MARK: Text (warm cream-white voice)
    static let textPrimary = Color(red: 0.957, green: 0.937, blue: 0.902)
    static let textSecondary = Color(red: 0.690, green: 0.655, blue: 0.608)
    static let textTertiary = Color(red: 0.435, green: 0.400, blue: 0.361)

    // MARK: Brand
    /// Vermillion — the "W" accent from the icon.
    static let accent = Color(red: 0.898, green: 0.259, blue: 0.122)
    static let accentBright = Color(red: 0.945, green: 0.337, blue: 0.180)
    static let accentDeep = Color(red: 0.784, green: 0.208, blue: 0.059)
    static let accentSoft = Color(red: 0.898, green: 0.259, blue: 0.122).opacity(0.14)
    /// The cream of the icon's squircle — used sparingly as a light brand material.
    static let cream = Color(red: 0.925, green: 0.898, blue: 0.839)
    static let success = Color(red: 0.357, green: 0.725, blue: 0.545)
    static let danger = Color(red: 0.898, green: 0.259, blue: 0.122)

    // MARK: Lines
    static let stroke = Color.white.opacity(0.06)
    static let strokeStrong = Color.white.opacity(0.10)
    /// Faint top highlight that makes cards read as "lit from above".
    static let topHighlight = Color.white.opacity(0.05)

    // MARK: Geometry
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10

    // MARK: Gradients
    /// Window background — a subtle warm vertical wash, not flat.
    static let canvasGradient = LinearGradient(
        colors: [canvasTop, canvas],
        startPoint: .top,
        endPoint: .bottom
    )
    /// The signature action/selection fill.
    static let accentGradient = LinearGradient(
        colors: [accentBright, accentDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Semantic type scale on SF Pro, used deliberately. SF Mono is reserved for
/// technical readouts (model paths, versions, keycaps).
enum Typography {
    static let largeTitle = Font.system(size: 28, weight: .bold)
    static let title = Font.system(size: 19, weight: .semibold)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let subheadline = Font.system(size: 12.5, weight: .regular)
    static let caption = Font.system(size: 11, weight: .medium)
    static let kicker = Font.system(size: 11, weight: .bold)
    static let label = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
}
