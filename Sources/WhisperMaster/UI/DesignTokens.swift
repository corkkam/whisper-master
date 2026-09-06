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

    static let logo: NSImage? = tile(named: "WhisperMasterLogo")

    private static func tile(named name: String) -> NSImage? {
        guard let url = resourceBundle?.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    // Laid out for the boxes `BrandLogo` actually asks for (34pt sidebar, 58pt
    // About), stored at 4×. Full-bleed — `BrandLogo` clips the corner itself.
    private static let smallTile: NSImage? = tile(named: "WhisperMasterLogoSmall")
    private static let mediumTile: NSImage? = tile(named: "WhisperMasterLogoMedium")

    /// The tile to show at `points`.
    ///
    /// ⚠️ The mark is a field of dots, and **a dot field cannot be downscaled** —
    /// the same rule that makes the tray glyph its own asset. Handing SwiftUI
    /// the 1024 tile and letting `.resizable()` fit it into 34pt put ~450 dots
    /// into 34 points and the logo rendered as a brown smudge. So each box gets
    /// a tile whose field was laid out for it (`Scripts/make-logo.swift`), and
    /// this ladder is hand-stepped to match the sizes that exist rather than
    /// interpolated. Add a call site at a new size and give it a tier.
    static func appTile(points: CGFloat) -> NSImage? {
        if points <= 44, let small = smallTile { return small }
        if points <= 96, let medium = mediumTile { return medium }
        return mediumTile ?? logo
    }

    /// The orb for use as a status-bar (tray) icon, as a **template** image:
    /// black at varying alpha on a clear ground, so macOS tints it to match the
    /// system appearance. That is essential on the translucent menu bar
    /// (macOS 26+), where an opaque full-colour tile looks pasted on rather
    /// than part of the bar.
    ///
    /// ⚠️ This is its **own asset**, not the tile with its ground masked out.
    /// The mark is a field of ~450 dots (`Scripts/make-logo.swift`); a
    /// brightness cut over it keeps every one of them, and 450 dots in an 18pt
    /// box is a smudge. `make-logo.swift` draws the tray glyph separately at a
    /// density tuned for that box — six latitude rings, bold ink — the same way
    /// the orb itself ships two hand-tuned presets rather than one scaled
    /// design.
    static func trayTemplateImage(points: CGFloat) -> NSImage? {
        guard let glyph else { return nil }
        let image = NSImage(cgImage: glyph, size: NSSize(width: points, height: points))
        image.isTemplate = true
        return image
    }

    private static let glyph: CGImage? = {
        guard let url = resourceBundle?.url(forResource: "WhisperMasterTrayGlyph", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
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
            if let image = BrandAsset.appTile(points: size) {
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
