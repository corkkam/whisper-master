import Foundation

/// Applies the user's glossary to a finished transcript by plain text
/// replacement — the safe alternative to FluidAudio's streaming CTC rescorer,
/// which corrupts (empties/truncates) transcripts in streaming mode.
///
/// For each glossary entry, every whole-word occurrence of the canonical term
/// *or any of its aliases* (case-insensitive) is rewritten to the canonical
/// form. This fixes casing ("nvidia" → "NVIDIA") and known mishearings
/// ("laser" → "Lyzr", fed by the manual aliases and the auto-learn feature).
/// Deterministic and non-destructive: it can only substitute words, never drop
/// them.
enum VocabularyPostProcessor {
    /// Terms shorter than this are ignored to avoid rewriting incidental short
    /// words; mirrors FluidAudio's own `minTermLength` guard.
    private static let minLength = 2

    static func apply(_ text: String, glossary lines: [String]) -> String {
        applyCounting(text, glossary: lines).text
    }

    /// Like `apply`, but also reports how many whole-word substitutions actually
    /// changed the text — the "dictionary fixes" figure on the usage dashboard.
    /// Only replacements whose matched text differs from the canonical form
    /// count (a form already in canonical shape is a no-op, not a fix).
    static func applyCounting(_ text: String, glossary lines: [String]) -> (text: String, substitutions: Int) {
        guard !text.isEmpty else { return (text, 0) }
        let terms = lines.compactMap { VocabularyTermParser.parse($0) }
        guard !terms.isEmpty else { return (text, 0) }

        var result = text
        var substitutions = 0
        for term in terms {
            let canonical = term.text
            // Longer forms first so a multi-word alias wins over its own words.
            let forms = ([canonical] + term.aliases)
                .filter { $0.count >= minLength }
                .sorted { $0.count > $1.count }
            for form in forms {
                // Skip a form that already equals the canonical exactly — nothing
                // to change — but still run when only the casing differs.
                if form == canonical { continue }
                let (next, n) = replaceWholeWord(in: result, form: form, with: canonical)
                result = next
                substitutions += n
            }
            // Normalize casing of the canonical itself (e.g. "Nvidia" → "NVIDIA").
            let (next, n) = replaceWholeWord(in: result, form: canonical, with: canonical)
            result = next
            substitutions += n
        }
        return (result, substitutions)
    }

    /// Case-insensitive whole-word replacement that preserves surrounding
    /// punctuation and spacing. Word boundaries keep "rag" from touching
    /// "ragged" or "storage".
    private static func replaceWholeWord(in text: String, form: String, with replacement: String) -> (text: String, count: Int) {
        let escaped = NSRegularExpression.escapedPattern(for: form)
        // Custom boundaries: a form may start/end with non-word chars, so anchor
        // on "not a letter/digit" rather than \b (which fails around such forms).
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (text, 0)
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        // Count only matches whose text actually differs from the replacement, so
        // an already-canonical occurrence isn't tallied as a correction.
        let matches = regex.matches(in: text, options: [], range: fullRange)
        var changed = 0
        for match in matches {
            if let r = Range(match.range, in: text), String(text[r]) != replacement { changed += 1 }
        }
        let escapedReplacement = NSRegularExpression.escapedTemplate(for: replacement)
        let result = regex.stringByReplacingMatches(in: text, options: [], range: fullRange, withTemplate: escapedReplacement)
        return (result, changed)
    }
}
