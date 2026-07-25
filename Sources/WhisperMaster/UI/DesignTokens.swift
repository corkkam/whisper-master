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

    /// The brand level-meter mark for use as a status-bar (tray) icon, as a
    /// **template** image: the dark squircle is dropped, leaving just the bars'
    /// silhouette so macOS tints it to match the system appearance. This is
    /// essential on the translucent menu bar (macOS 26+), where an opaque
    /// full-color logo tile looks pasted-on rather than part of the bar.
    static func trayTemplateImage(points: CGFloat) -> NSImage? {
        guard let glyphMask, glyphMask.height > 0 else { return nil }
        // The cropped mask isn't exactly square; fit it to `points` tall rather
        // than stretching it into a square box.
        let aspect = CGFloat(glyphMask.width) / CGFloat(glyphMask.height)
        let image = NSImage(cgImage: glyphMask, size: NSSize(width: points * aspect, height: points))
        image.isTemplate = true
        return image
    }

    /// The logo with everything but the meter bars masked out (black on a clear
    /// background), cropped to the bars, computed once. The mark's ground is
    /// near-black (`#07090e`, plus a dim ember glow at the bottom) and the bars
    /// are vivid, so a brightness cut separates them: any pixel whose brightest
    /// channel clears the threshold is glyph, everything else is dropped. The
    /// threshold sits well above the brightest glow pixel and well below either
    /// bar colour, so neither the ground nor the anti-aliased squircle edge can
    /// leak in.
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

        let brightnessThreshold = 0.5
        var minX = width, minY = height, maxX = -1, maxY = -1
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            // Un-premultiply so anti-aliased edges are judged on their own colour.
            var r = 0.0, g = 0.0, b = 0.0
            if alpha > 0 {
                r = Double(pixels[index]) / 255 / alpha
                g = Double(pixels[index + 1]) / 255 / alpha
                b = Double(pixels[index + 2]) / 255 / alpha
            }
            let isGlyph = alpha > 0.5 && max(r, g, b) > brightnessThreshold

            pixels[index] = 0
            pixels[index + 1] = 0
            pixels[index + 2] = 0
            pixels[index + 3] = isGlyph ? 255 : 0

            guard isGlyph else { continue }
            let pixel = index / 4
            let x = pixel % width, y = pixel / width
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        guard let mask = context.makeImage() else { return nil }
        // Crop to the bars so the tray glyph fills its 18pt box instead of
        // inheriting the squircle's generous margin.
        guard maxX >= minX, maxY >= minY else { return mask }
        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return mask.cropping(to: box) ?? mask
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
                    .fill(Theme.accentFill)
                    .overlay(
                        Text("W")
                            .font(.system(size: size * 0.52, weight: .heavy))
                            .foregroundStyle(Theme.accentOn)
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
