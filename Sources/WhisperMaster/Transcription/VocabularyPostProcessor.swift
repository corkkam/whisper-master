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
        guard !text.isEmpty else { return text }
        let terms = lines.compactMap { VocabularyTermParser.parse($0) }
        guard !terms.isEmpty else { return text }

        var result = text
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
                result = replaceWholeWord(in: result, form: form, with: canonical)
            }
            // Normalize casing of the canonical itself (e.g. "Nvidia" → "NVIDIA").
            result = replaceWholeWord(in: result, form: canonical, with: canonical)
        }
        return result
    }

    /// Case-insensitive whole-word replacement that preserves surrounding
    /// punctuation and spacing. Word boundaries keep "rag" from touching
    /// "ragged" or "storage".
    private static func replaceWholeWord(in text: String, form: String, with replacement: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: form)
        // Custom boundaries: a form may start/end with non-word chars, so anchor
        // on "not a letter/digit" rather than \b (which fails around such forms).
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let escapedReplacement = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: escapedReplacement)
    }
}
