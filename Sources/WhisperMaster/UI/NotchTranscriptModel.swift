import AppKit
import SwiftUI

/// Text measurement for the notch band, matched to `Typography.notchBody`.
///
/// The rolling transcript breaks its own lines (see `NotchTranscriptModel`), so
/// it needs the same advance widths `Text` will use. Widths are memoised — the
/// same handful of words is re-measured on every streaming update.
enum NotchTextMetrics {
    /// Point size of `Typography.notchBody`.
    static let fontSize: CGFloat = 13

    /// The measuring font: the brand body face at the notch size and weight,
    /// falling back to the system face exactly as `Typography.sans` does.
    nonisolated(unsafe) static let font: NSFont = {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: BrandFont.body])
            .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.medium.rawValue]])
        return NSFont(descriptor: descriptor, size: fontSize)
            ?? .systemFont(ofSize: fontSize, weight: .medium)
    }()

    /// Height reserved per transcript line. The font's own line height plus a
    /// little slack, since each line is pinned to this height to keep the rolling
    /// window on a fixed grid — too tight and `Text` would clip its descenders.
    nonisolated(unsafe) static let lineHeight: CGFloat =
        ceil(font.ascender - font.descender + font.leading) + 2

    /// Gap between transcript lines. Deliberately tiny — this is a caption block
    /// on a 60pt band, not body copy.
    static let lineSpacing: CGFloat = 1

    /// Distance from one line's top to the next — what the window scrolls by.
    static var lineAdvance: CGFloat { lineHeight + lineSpacing }

    /// Advance width of the inter-word space, i.e. the `HStack` spacing the words
    /// are laid out with.
    nonisolated(unsafe) static let spaceWidth: CGFloat = measure(" ")

    /// Rendered width of a word, memoised.
    static func width(_ word: String) -> CGFloat {
        let key = word as NSString
        if let hit = cache.object(forKey: key) { return CGFloat(hit.doubleValue) }
        let value = measure(word)
        cache.setObject(NSNumber(value: Double(value)), forKey: key)
        return value
    }

    /// Height of a block of `lines` transcript rows.
    static func blockHeight(lines: Int) -> CGFloat {
        guard lines > 0 else { return 0 }
        return CGFloat(lines) * lineHeight + CGFloat(lines - 1) * lineSpacing
    }

    private static func measure(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// `NSCache` rather than a dictionary — it is thread-safe and self-trimming.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSNumber>()
}

/// The rolling notch transcript, resolved: the words the engine has emitted,
/// broken into lines that fit the band, with a three-line window onto the tail.
///
/// Line breaking happens here rather than inside a wrapped `Text` because the
/// band has to do three things `Text` cannot: grow with the number of lines,
/// slide older lines up out of view as new ones arrive, and animate each word in
/// on its own as the engine emits it. Widths are injected, so the arithmetic is
/// pure and covered by `NotchTranscriptModelTests`.
struct NotchTranscriptModel: Equatable {
    /// One rendered word. `isPartial` marks the volatile tail the engine may
    /// still revise — drawn a shade quieter than locked-in text.
    struct Word: Equatable {
        let text: String
        let isPartial: Bool
    }

    /// How many lines of transcript the band shows at once. Older lines scroll
    /// off the top.
    static let visibleLines = 3

    var words: [Word] = []
    /// Index ranges into `words`, one per wrapped line, in reading order.
    var lines: [Range<Int>] = []

    var isEmpty: Bool { words.isEmpty }

    /// First line still on screen — everything before it has scrolled off.
    var firstVisibleLine: Int { max(0, lines.count - Self.visibleLines) }

    /// How many lines are on screen, 1…`visibleLines`. Never zero, so the band
    /// doesn't collapse mid-dictation.
    var visibleLineCount: Int { min(max(lines.count, 1), Self.visibleLines) }

    /// Whether anything has scrolled off the top — the cue for the fade there.
    var hasScrolled: Bool { firstVisibleLine > 0 }
}

extension NotchTranscriptModel {
    /// Resolve the model for a confirmed/partial pair at a given text width.
    static func resolve(confirmed: String, partial: String, width: CGFloat) -> NotchTranscriptModel {
        let words = tokenize(confirmed: confirmed, partial: partial)
        return NotchTranscriptModel(
            words: words,
            lines: wrap(
                widths: words.map { NotchTextMetrics.width($0.text) },
                spacing: NotchTextMetrics.spaceWidth,
                maxWidth: width
            )
        )
    }

    /// Split the two runs into words, tagging the volatile tail. Whitespace is
    /// dropped — the layout re-inserts a single space between every pair.
    static func tokenize(confirmed: String, partial: String) -> [Word] {
        func words(_ text: String, isPartial: Bool) -> [Word] {
            text.split(whereSeparator: \.isWhitespace).map { Word(text: String($0), isPartial: isPartial) }
        }
        return words(confirmed, isPartial: false) + words(partial, isPartial: true)
    }

    /// Greedy line breaking: fill a line until the next word won't fit, then
    /// start a new one. A word wider than a whole line gets a line to itself (the
    /// `Text` truncates it) rather than looping forever.
    static func wrap(widths: [CGFloat], spacing: CGFloat, maxWidth: CGFloat) -> [Range<Int>] {
        guard !widths.isEmpty, maxWidth > 0 else { return [] }

        var lines: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0

        for (index, width) in widths.enumerated() {
            if index == start {
                used = width
                continue
            }
            let advance = spacing + width
            if used + advance > maxWidth {
                lines.append(start..<index)
                start = index
                used = width
            } else {
                used += advance
            }
        }

        lines.append(start..<widths.count)
        return lines
    }
}
