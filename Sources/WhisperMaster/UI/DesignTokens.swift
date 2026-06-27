import AppKit
import SwiftUI

/// The Whisper Master squircle mark, loaded once from the package resource.
enum BrandAsset {
    /// Name of the SwiftPM-generated resource bundle for this target.
    private static let resourceBundleName = "WhisperMaster_WhisperMaster.bundle"

    /// Resolve the resource bundle without relying on the generated
    /// `Bundle.module` accessor.
    ///
    /// `Bundle.module` only probes `Bundle.main.bundleURL` (the `.app` *root*,
    /// not `Contents/Resources`) and an absolute `.build` path baked in at
    /// compile time — and it `fatalError`s when neither exists. In a packaged
    /// `.app` the resource bundle correctly lives in `Contents/Resources/`
    /// (the only codesign-safe location), which that accessor never checks,
    /// so touching `Bundle.module` crashes the app on launch. We probe the
    /// real locations ourselves and return `nil` instead of trapping.
    private static let resourceBundle: Bundle? = {
        let candidates: [URL?] = [
            // Packaged `.app`: Contents/Resources/<bundle>
            Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName),
            // Dev (`swift run`) and legacy `.app`-root layouts: next to the executable
            Bundle.main.bundleURL.appendingPathComponent(resourceBundleName),
        ]
        for url in candidates.compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        // Last resort: the resource may have been flattened into the main bundle.
        return Bundle.main
    }()

    static let logo: NSImage? = {
        guard let url = resourceBundle?.url(forResource: "WhisperMasterLogo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// The brand "W" for use as a status-bar (tray) icon, as a **template**
    /// image: the cream squircle is dropped, leaving just the glyph silhouette
    /// so macOS tints it to match the system appearance. This is essential on
    /// the translucent menu bar (macOS 26+), where an opaque full-color logo
    /// tile looks pasted-on rather than part of the bar.
    static func trayTemplateImage(points: CGFloat) -> NSImage? {
        guard let glyphMask else { return nil }
        let image = NSImage(cgImage: glyphMask, size: NSSize(width: points, height: points))
        image.isTemplate = true
        return image
    }

    /// The logo with everything but the "W" strokes masked out (black on a
    /// clear background), computed once. Any pixel close to the squircle's
    /// cream is dropped; the dark and red strokes are kept as the silhouette.
    private static let glyphMask: CGImage? = {
        guard let logo,
              let source = logo.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let width = source.width
        let height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        let cream = (r: 0.90, g: 0.88, b: 0.82)
        let tolerance = 0.22
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            // Un-premultiply so anti-aliased cream edges aren't misread as glyph.
            var r = 0.0, g = 0.0, b = 0.0
            if alpha > 0 {
                r = Double(pixels[index]) / 255 / alpha
                g = Double(pixels[index + 1]) / 255 / alpha
                b = Double(pixels[index + 2]) / 255 / alpha
            }
            let isGlyph = alpha > 0.5
                && max(abs(r - cream.r), abs(g - cream.g), abs(b - cream.b)) > tolerance

            pixels[index] = 0
            pixels[index + 1] = 0
            pixels[index + 2] = 0
            pixels[index + 3] = isGlyph ? 255 : 0
        }
        return context.makeImage()
    }()
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
                    .fill(Theme.accent)
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

// MARK: - Studio theme (LEGACY — onboarding only, removed in Phase 3)
//
// The old warm "audio plugin" cream look. The settings window has moved to the
// new `Theme`; this block is kept only until the onboarding wizard is restyled,
// after which it (and StudioFont/StudioButton/StudioToggleStyle below) is deleted.

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
