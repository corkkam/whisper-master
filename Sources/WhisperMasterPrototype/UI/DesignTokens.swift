import AppKit
import SwiftUI

/// The Whisper Master squircle mark, loaded once from the package resource.
enum BrandAsset {
    static let logo: NSImage? = {
        guard let url = Bundle.module.url(forResource: "WhisperMasterLogo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// A copy of the logo scaled to `points` for use as a status-bar (tray)
    /// icon. Not a template image — we want to keep the brand colors.
    static func trayImage(points: CGFloat) -> NSImage? {
        guard let logo else { return nil }
        let size = NSSize(width: points, height: points)
        let scaled = NSImage(size: size)
        scaled.lockFocus()
        logo.draw(in: NSRect(origin: .zero, size: size),
                  from: .zero, operation: .sourceOver, fraction: 1)
        scaled.unlockFocus()
        scaled.isTemplate = false
        return scaled
    }
}

/// The Whisper Master squircle mark, bundled as a package resource. Falls back
/// to the drawn "W" monogram if the asset can't be loaded.
struct BrandLogo: View {
    var size: CGFloat
    var cornerRadius: CGFloat?

    init(size: CGFloat, cornerRadius: CGFloat? = nil) {
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Group {
            if let image = BrandAsset.logo {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.24, style: .continuous)
                    .fill(Studio.red)
                    .overlay(
                        Text("W")
                            .font(.system(size: size * 0.52, weight: .heavy))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.24, style: .continuous))
    }
}

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

// MARK: - Studio theme (settings window)
//
// A warm "audio plugin" look: cream canvas, near-black sidebar, vermillion
// accent. Kept separate from `Palette` (the dark dictation theme used by the
// onboarding wizard + pill) so the two surfaces can evolve independently.

enum Studio {
    static let bg = Color(red: 0.906, green: 0.882, blue: 0.824)
    static let surface = Color(red: 0.949, green: 0.929, blue: 0.878)
    static let sidebar = Color(red: 0.094, green: 0.083, blue: 0.071)
    static let dark = Color(red: 0.122, green: 0.106, blue: 0.090)

    static let red = Color(red: 0.851, green: 0.247, blue: 0.137)
    static let green = Color(red: 0.235, green: 0.557, blue: 0.318)
    static let greenDark = Color(red: 0.42, green: 0.78, blue: 0.50)

    static let ink = Color(red: 0.118, green: 0.106, blue: 0.094)
    static let inkSecondary = Color(red: 0.46, green: 0.43, blue: 0.39)
    static let inkTertiary = Color(red: 0.60, green: 0.56, blue: 0.51)

    static let cream = Color(red: 0.93, green: 0.91, blue: 0.86)
    static let creamSecondary = Color(red: 0.64, green: 0.61, blue: 0.55)
    static let creamTertiary = Color(red: 0.42, green: 0.40, blue: 0.37)

    static let cardBorder = Color.black.opacity(0.16)
    static let cardShadow = Color.black.opacity(0.10)
    static let divider = Color.black.opacity(0.07)
    static let switchOff = Color(red: 0.74, green: 0.71, blue: 0.66)

    static let waveBar = Color(red: 0.20, green: 0.18, blue: 0.16)
    static let waveBarSoft = Color(red: 0.45, green: 0.43, blue: 0.40)
}

enum StudioFont {
    /// Sans family for the settings UI. Avenir Next ships on every Mac, so no
    /// font bundling/registration is needed. Swap this one string to retheme.
    static let family = "Avenir Next"

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(family, size: size).weight(weight)
    }

    static let display = sans(46, .heavy)
    static let cardTitle = sans(18, .bold)
    static let cardBody = sans(14, .regular)
    static let subtitle = sans(16, .regular)
    static let stat = sans(44, .heavy)
    // Monospace labels stay on SF Mono — that's the studio "readout" voice.
    static let mono = Font.system(size: 12, weight: .bold, design: .monospaced)
    static let monoSmall = Font.system(size: 10, weight: .bold, design: .monospaced)
}

/// Pill button: filled vermillion or outlined. `onDark` flips the outline
/// variant to cream text/border for use on dark surfaces.
struct StudioButton: View {
    let title: String
    var icon: String?
    var filled: Bool
    var onDark: Bool = false
    let action: () -> Void

    private var outlineColor: Color { onDark ? Studio.cream : Studio.ink }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .bold))
                }
                Text(title).font(StudioFont.sans(13, .bold))
            }
            .foregroundStyle(filled ? .white : outlineColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(filled ? Studio.red : Color.white.opacity(0.0001))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(filled ? Color.clear : outlineColor.opacity(0.55), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// The chunky vermillion rocker switch used throughout the studio settings.
struct StudioToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isOn ? Studio.red : Studio.switchOff)
                    .frame(width: 62, height: 32)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Capsule()
                            .fill(configuration.isOn ? Studio.red.opacity(0.65) : Studio.switchOff)
                            .frame(width: 2, height: 9)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .padding(4)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isOn)
    }
}
