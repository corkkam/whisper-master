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

    /// Resolve a bundled resource URL by name + extension, using the same probe
    /// as `logo`. `.process("Resources")` may flatten the `Fonts/` folder or keep
    /// it as a subdirectory, so we try both. Used to register the bundled fonts.
    static func resourceURL(named name: String, withExtension ext: String) -> URL? {
        let bundles = [resourceBundle, Bundle.main].compactMap { $0 }
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: ext) { return url }
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fonts") { return url }
        }
        return nil
    }

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

// The settings window and onboarding both use the shared `Theme` (see
// Theme.swift). BrandAsset/BrandLogo above are the only brand-specific helpers
// that still live here.
