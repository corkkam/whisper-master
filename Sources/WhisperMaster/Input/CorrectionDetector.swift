import Foundation

/// Detects when the user fixed a single misheard word in freshly pasted text.
///
/// Pure and deterministic: compares the injected sentence against the field's
/// text after the user edited it. Fires only for an unambiguous single-word
/// replacement that still *sounds like* a mishearing (spelling similarity
/// gate), so style edits ("great" → "awesome") are never learned.
enum CorrectionDetector {
    struct Correction: Equatable {
        /// The word the engine wrote (becomes the vocabulary alias).
        let heard: String
        /// The word the user typed instead (becomes the canonical term).
        let typed: String
    }

    /// A replacement is only a plausible *mishearing* when the spellings are
    /// at least this similar (1 - normalizedLevenshtein). Style edits swap in
    /// unrelated words and fall well below it.
    private static let minSimilarity = 0.3

    /// Need this much surrounding context to trust the alignment.
    private static let minWordCount = 3

    static func detectSingleWordReplacement(injected: String, current: String) -> Correction? {
        let injectedWords = words(from: injected)
        let currentWords = words(from: current)
        guard injectedWords.count >= minWordCount,
              currentWords.count >= injectedWords.count
        else { return nil }

        // Slide the injected sentence over the field text; qualify windows
        // where exactly one word differs. Two windows disagreeing → ambiguous.
        var found: Correction?
        for start in 0...(currentWords.count - injectedWords.count) {
            var mismatchIndex: Int?
            var mismatches = 0
            for offset in 0..<injectedWords.count {
                if !equalWord(injectedWords[offset], currentWords[start + offset]) {
                    mismatches += 1
                    if mismatches > 1 { break }
                    mismatchIndex = offset
                }
            }
            guard mismatches == 1, let index = mismatchIndex else { continue }
            let candidate = Correction(
                heard: injectedWords[index],
                typed: currentWords[start + index]
            )
            if let found, found != candidate { return nil }
            found = candidate
        }

        guard let found,
              !found.typed.isEmpty, !found.heard.isEmpty,
              found.heard.lowercased() != found.typed.lowercased(),
              isPlausibleWord(found.typed),
              !isGluingArtifact(found),
              similarity(found.heard, found.typed) >= minSimilarity
        else { return nil }
        return found
    }

    /// A learnable canonical must look like a word the user typed — letters,
    /// digits, hyphens, apostrophes. Sentence punctuation inside the token
    /// ("right?The", "guess.Yeah") is stale field text mis-aligned against a
    /// fresh paste, never a real correction. (Terms like "Node.js" can still
    /// be added by hand in Settings; auto-learn stays conservative.)
    private static func isPlausibleWord(_ word: String) -> Bool {
        word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "'" }
    }

    /// If one side wholly contains the other ("offEverything" ⊇ "Everything"),
    /// the "correction" is two fragments glued in the field, not a respelling.
    /// Learning it would make the glossary rewrite the contained word forever.
    private static func isGluingArtifact(_ correction: Correction) -> Bool {
        let typed = correction.typed.lowercased()
        let heard = correction.heard.lowercased()
        return typed.contains(heard) || heard.contains(typed)
    }

    private static func words(from text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    private static func equalWord(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
    }

    /// 1 - normalized Levenshtein distance over lowercased words (0…1).
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs.lowercased()), b = Array(rhs.lowercased())
        if a.isEmpty || b.isEmpty { return 0 }
        var previous = Array(0...b.count)
        var row = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            row[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                row[j] = min(previous[j] + 1, row[j - 1] + 1, substitution)
            }
            swap(&previous, &row)
        }
        let distance = previous[b.count]
        return 1.0 - Double(distance) / Double(max(a.count, b.count))
    }
}
