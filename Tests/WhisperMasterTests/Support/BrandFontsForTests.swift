import AppKit
import CoreText

@testable import WhisperMaster

/// Registers the bundled brand faces so copy can be measured in the faces the
/// band really draws, and measures it.
///
/// The fit tests are a guard, not the judge: SwiftUI's line breaking and line
/// box differ a little from Core Text's, and the `WM_SNAPSHOT` render decides.
enum BrandFontsForTests {
    /// `<repo root>/Sources/WhisperMaster/Resources/Fonts`, counted from this
    /// file (`Support`, `WhisperMasterTests`, `Tests`, root) so the working
    /// directory does not matter.
    static let fontsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/WhisperMaster/Resources/Fonts")

    static var fontFiles: [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "ttf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static let didRegister: Bool = {
        for url in fontFiles {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return BrandFont.hasHeading && BrandFont.hasBody
    }()

    /// Registers the faces once per process. False if either brand family is
    /// still missing, which a fit test must treat as a failure.
    @discardableResult
    static func register() -> Bool { didRegister }

    /// The body face at a weight, picked by weight trait the way
    /// `Typography.sans(_:_:)` asks SwiftUI for it, so `sans(19, .bold)` is the
    /// 700 face and never the family's default face.
    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: BrandFont.body,
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// The PostScript name of the face in one of the bundled files.
    static func postScriptName(ofFile name: String) -> String? {
        let url = fontsDirectory.appendingPathComponent(name)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first
        else { return nil }
        return CTFontCopyPostScriptName(CTFontCreateWithFontDescriptor(first, 12, nil)) as String
    }

    /// Width of `text` on one line.
    static func width(_ text: String, _ font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// How many lines `text` wraps to at `width`.
    static func lineCount(_ text: String, _ font: NSFont, width: CGFloat) -> Int {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 10_000), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        return (CTFrameGetLines(frame) as? [CTLine])?.count ?? 0
    }

    /// The height AppKit gives one line of `font`.
    static func lineHeight(_ font: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }
}
