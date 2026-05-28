import SwiftUI

enum Palette {
    static let background = Color(red: 0.09, green: 0.085, blue: 0.082)
    static let surface = Color(red: 0.135, green: 0.128, blue: 0.123)
    static let surfaceElevated = Color(red: 0.165, green: 0.155, blue: 0.148)
    static let surfaceHover = Color(red: 0.19, green: 0.18, blue: 0.17)
    static let sidebar = Color(red: 0.07, green: 0.065, blue: 0.062)
    static let stroke = Color.white.opacity(0.06)
    static let strokeStrong = Color.white.opacity(0.10)

    static let textPrimary = Color(red: 0.94, green: 0.94, blue: 0.93)
    static let textSecondary = Color(red: 0.62, green: 0.60, blue: 0.58)
    static let textTertiary = Color(red: 0.42, green: 0.40, blue: 0.38)

    static let accent = Color(red: 0.98, green: 0.55, blue: 0.22)
    static let accentSoft = Color(red: 0.98, green: 0.55, blue: 0.22).opacity(0.18)
    static let success = Color(red: 0.36, green: 0.82, blue: 0.50)
    static let danger = Color(red: 0.94, green: 0.36, blue: 0.36)
}

enum Typography {
    static let display = Font.system(size: 30, weight: .bold, design: .default)
    static let title = Font.system(size: 20, weight: .bold, design: .default)
    static let heading = Font.system(size: 15, weight: .bold, design: .default)
    static let body = Font.system(size: 13, weight: .semibold, design: .default)
    static let bodyRegular = Font.system(size: 13, weight: .regular, design: .default)
    static let caption = Font.system(size: 11, weight: .semibold, design: .default)
    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let sectionLabel = Font.system(size: 10, weight: .heavy, design: .default)
}

struct Card: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.stroke, lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View {
        modifier(Card(padding: padding))
    }
}
