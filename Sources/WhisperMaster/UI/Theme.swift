import SwiftUI

/// The Whisper Master design system: a warm, professional "not fully dark, not
/// fully white" palette drawn straight from the app icon — charcoal and
/// vermillion on cream, inverted into a charcoal canvas with cream text and a
/// vermillion accent. One cohesive theme for the settings window and onboarding.
enum Theme {
    // MARK: Surfaces
    /// Window background — warm charcoal, not pure black.
    static let canvas = Color(red: 0.102, green: 0.090, blue: 0.078)
    /// Card / grouped-control background.
    static let surface = Color(red: 0.137, green: 0.125, blue: 0.118)
    /// Nested / hovered fills sitting on top of `surface`.
    static let surfaceElevated = Color(red: 0.176, green: 0.161, blue: 0.149)
    /// The slightly deeper sidebar rail.
    static let sidebar = Color(red: 0.078, green: 0.071, blue: 0.063)

    // MARK: Text
    static let textPrimary = Color(red: 0.949, green: 0.929, blue: 0.890)
    static let textSecondary = Color(red: 0.655, green: 0.627, blue: 0.600)
    static let textTertiary = Color(red: 0.431, green: 0.408, blue: 0.384)

    // MARK: Brand / status
    /// Vermillion — the "W" accent from the icon.
    static let accent = Color(red: 0.878, green: 0.220, blue: 0.118)
    static let accentSoft = Color(red: 0.878, green: 0.220, blue: 0.118).opacity(0.16)
    static let success = Color(red: 0.310, green: 0.706, blue: 0.467)
    static let danger = Color(red: 0.878, green: 0.220, blue: 0.118)

    // MARK: Lines
    static let stroke = Color.white.opacity(0.07)
    static let strokeStrong = Color.white.opacity(0.12)

    // MARK: Geometry
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 9
}

/// Semantic type scale, on SF Pro (system) — used deliberately rather than the
/// previous bespoke Avenir/monospace mix. SF Mono is reserved for genuinely
/// technical readouts (model paths, version strings).
enum Typography {
    static let largeTitle = Font.system(size: 26, weight: .bold)
    static let title = Font.system(size: 19, weight: .semibold)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let subheadline = Font.system(size: 12, weight: .regular)
    static let caption = Font.system(size: 11, weight: .medium)
    static let label = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
}
