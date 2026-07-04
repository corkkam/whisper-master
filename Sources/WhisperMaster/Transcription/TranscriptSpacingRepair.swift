import Foundation

/// Repairs a missing space where the streaming ASR glued a sentence boundary
/// straight onto the next word — e.g. "right?The" → "right? The",
/// "guess.Yeah" → "guess. Yeah". v2's token reconstruction can drop the
/// inter-word space at a window/segment boundary when the speaker pauses.
///
/// Deliberately conservative: it only inserts a space when a `.`/`!`/`?`/`,`
/// is immediately followed by an **uppercase** letter (a new sentence/word).
/// That leaves "gmail.com", "3.5", and "e.g." untouched, because those are
/// followed by a lowercase letter or a digit.
enum TranscriptSpacingRepair {
    private static let glued = try? NSRegularExpression(pattern: "([.!?,])(\\p{Lu})")

    static func repair(_ text: String) -> String {
        guard !text.isEmpty, let glued else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return glued.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1 $2")
    }
}
