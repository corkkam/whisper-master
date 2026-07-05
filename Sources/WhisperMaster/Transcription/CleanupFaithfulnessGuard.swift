import Foundation

/// Deterministic safety net for the on-device LLM cleanup pass.
///
/// qwen2.5-3B cleans dictation well but occasionally *breaks character* — it
/// answers a question, runs a command, translates, writes code, or obeys a
/// prompt injection instead of just cleaning the sentence. Those outputs are
/// worse than doing nothing: the user would see typed text they never spoke.
///
/// This guard compares the model's output against the text we fed it and
/// **rejects** (caller keeps the deterministic-cleaned original) whenever the
/// output diverges in a way a faithful cleanup never would. It is pure and
/// deterministic so it can be unit-tested against real qwen outputs.
///
/// Design (tuned to observed qwen2.5-3B failures):
///  - The **primary** signal is *invented content*: a cleanup only removes,
///    reorders, reformats, and re-punctuates — it never introduces a new
///    content word. An output content word that traces to nothing in the input
///    (e.g. "Paris", "buenos", "def", "None") is the tell for answering /
///    translating / coding / summarizing. High precision, so tolerance is zero.
///  - Numbers/symbols are exempt from that check (spoken → "$25"/"4:30"/"25%"
///    is legitimate and won't match input *words*), and stopwords/fillers are
///    exempt too (cleanup may legitimately add "the"/"is"/punctuation).
///  - A **loose** length band catches gross expansion (rambling answer) and
///    gross truncation (e.g. injection "…say hello" → "Hello."). The band is
///    deliberately wide so it never fires on legitimate filler/self-correction
///    compression (observed real case: "revenue grew twenty five percent last
///    quarter" → "Revenue grew 25%." is a 0.43× drop and must pass).
///  - Code fences are a direct reject.
///
/// Known accepted residual: an imperative that the model shortens using only
/// spoken words (observed: "translate good morning into spanish" → "Good
/// morning.") slips through as a harmless fragment — it did NOT produce a
/// translation. Catching it would require rejecting legitimate self-correction
/// compression, which is the feature's whole point, so we accept the fragment.
enum CleanupFaithfulnessGuard {

    /// Wide expansion ceiling — a faithful cleanup is never much longer than the
    /// input; a model that starts answering balloons past this.
    static let maxExpansionRatio = 1.6
    /// Gross-truncation floor, applied only to inputs of at least this many words
    /// (short inputs swing wildly in ratio and are handled by the content check).
    static let minRetentionRatio = 0.3
    static let truncationFloorMinWords = 5

    /// Returns `true` when `cleaned` is a plausibly faithful cleanup of
    /// `original`, `false` when the caller should discard it and keep `original`.
    static func accept(original: String, cleaned: String) -> Bool {
        let out = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return false }

        // Code fences / obvious code blocks are never a cleaned sentence.
        if out.contains("```") { return false }

        let inputWords = wordCount(original)
        let outputWords = wordCount(out)

        // Length band (loose — see doc comment).
        if inputWords > 0 {
            let ratio = Double(outputWords) / Double(inputWords)
            if ratio > maxExpansionRatio { return false }
            if inputWords >= truncationFloorMinWords, ratio < minRetentionRatio { return false }
        }

        // A cleanup of a sentence with real (non-number) words always yields
        // words. If the input has content words but the output is only numbers /
        // symbols — "15 * 12 = 180", "1 2 3 4 5" — the model computed or executed
        // the utterance instead of cleaning it.
        if !contentTokens(original).isEmpty, contentTokens(out).isEmpty { return false }

        // Invented-content + invented-repetition check: a faithful cleanup only
        // removes / reorders / reformats — it never introduces a content word the
        // input didn't have, and never *multiplies* one (e.g. a prompt injection
        // echoing "pineapple pineapple pineapple"). So each output content word
        // must not occur more times than it did in the input.
        var inputCounts: [String: Int] = [:]
        for stemmed in alphabeticTokens(original).map(stem) { inputCounts[stemmed, default: 0] += 1 }
        var outputCounts: [String: Int] = [:]
        for token in contentTokens(out) { outputCounts[stem(token), default: 0] += 1 }
        for (word, count) in outputCounts where count > (inputCounts[word] ?? 0) {
            return false
        }
        return true
    }

    // MARK: - Tokenizing

    private static func wordCount(_ s: String) -> Int {
        s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }

    /// All alphabetic tokens (lowercased, contractions expanded, numbers/symbols
    /// dropped) — the membership set the output is checked against.
    private static func alphabeticTokens(_ s: String) -> [String] {
        expand(s.lowercased())
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { tok in tok.allSatisfy(\.isLetter) && !tok.isEmpty }
    }

    /// Output tokens that a faithful cleanup could NOT have invented: alphabetic,
    /// not a stopword or filler, longer than one character. Number/symbol tokens
    /// (containing a digit) are excluded — reformatting spoken numbers is fine.
    private static func contentTokens(_ s: String) -> [String] {
        expand(s.lowercased())
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { tok in
                tok.count > 1
                    && tok.allSatisfy(\.isLetter)
                    && !stopwords.contains(tok)
                    && !fillers.contains(tok)
                    && !numberWords.contains(tok)
            }
    }

    /// Very light stemmer so plural/tense shifts ("log"/"logs") don't read as
    /// invented content, while genuinely new words still stand out.
    private static func stem(_ w: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where w.count > suffix.count + 2 && w.hasSuffix(suffix) {
            return String(w.dropLast(suffix.count))
        }
        return w
    }

    /// Expand the common contractions cleanup may introduce, so "don't" traces to
    /// input "do not" (and vice versa) rather than looking like a new word.
    private static func expand(_ s: String) -> String {
        var out = s
        for (contraction, expansion) in contractions {
            out = out.replacingOccurrences(of: contraction, with: expansion)
        }
        return out
    }

    private static let contractions: [(String, String)] = [
        ("won't", "will not"), ("can't", "can not"), ("n't", " not"),
        ("i'm", "i am"), ("let's", "let us"), ("'ll", " will"),
        ("'re", " are"), ("'ve", " have"), ("'d", " would"),
        ("it's", "it is"), ("that's", "that is"), ("what's", "what is"),
        ("he's", "he is"), ("she's", "she is"), ("there's", "there is"),
    ]

    /// Function words a cleanup may freely add/drop. Exempt from the invented-
    /// content check (adding an article or auxiliary is not "inventing content").
    private static let stopwords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being", "am",
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them",
        "my", "your", "his", "its", "our", "their", "this", "that", "these", "those",
        "to", "of", "in", "on", "at", "for", "with", "and", "or", "but", "so", "if",
        "then", "as", "by", "from", "up", "out", "about", "into", "over", "off",
        "do", "does", "did", "have", "has", "had", "will", "would", "can", "could",
        "should", "may", "might", "must", "not", "no", "yes", "there", "here",
        "what", "when", "where", "who", "why", "how", "which", "whom", "whose",
    ]

    /// Spoken fillers — a cleanup removes these, never adds them, so an added one
    /// is not a faithfulness violation. Kept in sync in spirit with FillerWordFilter.
    private static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "er", "erm", "ah", "ahh", "hmm", "hm", "mm", "mmm",
        "mhm", "like", "well", "okay", "ok", "yeah", "just", "really", "actually",
        "basically", "literally", "sorta", "kinda",
    ]

    /// Spoken number words. Excluded from the "content" set because numbers are
    /// legitimately reformatted to digits — so "twenty five" → "25" is not a
    /// wordless output, and the ITN-friendly spoken forms don't count as invented
    /// content when they move around.
    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
        "thousand", "million", "billion", "dozen", "oh", "point", "half",
    ]
}
