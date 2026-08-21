import Foundation

/// Removes unambiguous spoken fillers ("um", "uh", "hmm", …) from a transcript.
///
/// Only sounds that are never real English words get stripped — ambiguous
/// fillers ("like", "so", "well", "you know") stay, because deleting a real
/// word is worse than leaving a filler in. Pure and deterministic, cheap
/// enough to run on every streaming partial.
enum FillerWordFilter {
    /// Lowercased filler cores, compared after surrounding punctuation is
    /// stripped. "err" is deliberately absent ("to err is human"); all-caps
    /// tokens like "ER" (emergency room) are guarded against in `isFiller`.
    private static let fillers: Set<String> = [
        "um", "umm", "ummm", "uhm", "uhmm",
        "uh", "uhh", "uhhh",
        "er", "erm", "ermm",
        "ah", "ahh", "ahhh",
        "hm", "hmm", "hmmm", "hmmmm",
        "m", "mm", "mmm", "mmmm",
        "mhm", "mhmm", "mm-hmm", "mmhmm",
        "uh-huh", "uhhuh", "huh",
    ]

    // Candidates for a future "aggressive" mode — NOT removed today because
    // each is a real word in normal speech: "like", "so", "well", "right",
    // "you know", "i mean", "kind of", "sort of", "actually", "basically".

    private static let leadingPunctuation = CharacterSet(charactersIn: "([{\"'“‘¿¡")
    private static let trailingPunctuation = CharacterSet(charactersIn: ",.!?;:)]}\"'”’…")
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]

    static func clean(_ text: String) -> String {
        cleanCounting(text).text
    }

    /// Like `clean`, but also reports how many filler tokens were dropped — the
    /// "words corrected" contribution to the usage dashboard's fixes count.
    static func cleanCounting(_ text: String) -> (text: String, removed: Int) {
        guard !text.isEmpty else { return (text, 0) }

        var kept: [String] = []
        var pendingLeading = ""
        var capitalizeNext = false
        var removed = 0

        for token in text.split(whereSeparator: \.isWhitespace) {
            let (leading, core, trailing) = splitPunctuation(String(token))
            guard isFiller(core) else {
                var word = pendingLeading + leading + core + trailing
                pendingLeading = ""
                if capitalizeNext {
                    word = capitalizedIfSafe(word)
                    capitalizeNext = false
                }
                kept.append(word)
                continue
            }

            // A sentence-final mark on the filler belongs to the sentence:
            // "That's all, hmm." must keep its period.
            if let ender = trailing.last, sentenceEnders.contains(ender),
               var previous = kept.last,
               !(previous.last.map(sentenceEnders.contains) ?? false) {
                if previous.last == "," { previous.removeLast() }
                previous.append(ender)
                kept[kept.count - 1] = previous
            }
            pendingLeading += leading
            removed += 1
            // Dropping a sentence-opening filler ("Um, hello") leaves the next
            // word to start the sentence — it needs the capital.
            if kept.isEmpty || (kept.last?.last.map(sentenceEnders.contains) ?? false) {
                capitalizeNext = true
            }
        }

        return (kept.joined(separator: " "), removed)
    }

    /// Whether a bare token is one of the fillers this filter would drop.
    /// Exposed so `SelfCorrectionCollapser` can step over an "um" sitting inside a
    /// correction ("twenty um no thirty") — fillers are stripped later in the
    /// pipeline, so they are still present when it runs.
    static func isFillerWord(_ token: String) -> Bool {
        isFiller(splitPunctuation(token).core)
    }

    private static func isFiller(_ core: String) -> Bool {
        guard !core.isEmpty else { return false }
        // "ER", "UM" etc. spoken as initialisms come through all-caps; a real
        // filler never does.
        if core.count > 1, core == core.uppercased(), core != core.lowercased() {
            return false
        }
        // A lone "m"/"M" is a filler only when lowercase — preserve an
        // intentional capital letter (e.g. "plan M", a grade "M").
        if core.count == 1, core != core.lowercased() {
            return false
        }
        return fillers.contains(core.lowercased())
    }

    private static func splitPunctuation(_ token: String) -> (leading: String, core: String, trailing: String) {
        var scalars = Substring(token).unicodeScalars
        var leading = String.UnicodeScalarView()
        var trailing = String.UnicodeScalarView()
        while let first = scalars.first, leadingPunctuation.contains(first) {
            leading.append(first)
            scalars.removeFirst()
        }
        while let last = scalars.last, trailingPunctuation.contains(last) {
            trailing.append(last)
            scalars.removeLast()
        }
        return (String(leading), String(String.UnicodeScalarView(scalars)), String(String.UnicodeScalarView(trailing.reversed())))
    }

    /// Uppercase the first letter, but only when the word is otherwise fully
    /// lowercase — "iPhone" must not become "IPhone".
    private static func capitalizedIfSafe(_ word: String) -> String {
        guard let index = word.firstIndex(where: { $0.isLetter }) else { return word }
        let letter = word[index]
        guard letter.isLowercase, !word.contains(where: { $0.isUppercase }) else { return word }
        return word.replacingCharacters(in: index...index, with: String(letter).uppercased())
    }
}
