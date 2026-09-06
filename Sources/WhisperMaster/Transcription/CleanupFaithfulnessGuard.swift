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

    /// Grammar-polish mode rephrases, so it needs a looser band: a wider
    /// expansion ceiling (connectives/articles get added) and, instead of exact
    /// content-word containment, a cap on how much of the output can be *new*
    /// content the input never had (real polishing keeps most of the original
    /// nouns/names; wholesale-new content means the model answered or expanded).
    static let rephraseMaxExpansionRatio = 2.0
    static let rephraseMaxNovelContentFraction = 0.5

    /// **A long input gets a tight band, and this is the check that was missing.**
    ///
    /// The ratios above are loose on purpose: on a six-word utterance a faithful
    /// cleanup really can halve or double the count, so a tight band there rejects
    /// legitimate self-corrections and compressions. That reasoning does not carry
    /// to a 500-word dictation, and applying the short-input band to one is how the
    /// eval caught the model returning **207 words of a 521-word paragraph** — 60%
    /// of it silently gone — and the guard waving it through at 0.40 against a 0.30
    /// floor. A degenerate *loop* got through the same gap from the other side, at
    /// 1.47 against a 2.0 ceiling.
    ///
    /// Over `longFormMinWords` the law of large numbers applies: removing fillers
    /// and collapsing corrections moves a long transcript by a few percent, not by
    /// half. So the band closes to something a faithful pass comfortably meets and
    /// neither pathology can.
    /// Each of the three long-form failures the eval produced needs a *different*
    /// instrument, and that is why this is not one wider ratio:
    ///
    /// - **207 of 521 words**, ending cleanly — a ratio catches it, nothing else can.
    /// - **765 of 521, one sentence 19×** — the expansion ceiling catches it.
    /// - **437 of 521, stopping on the word "We"** — ratio 0.84, which no floor can
    ///   reject without also rejecting the good 0.95 pass beside it. What makes it
    ///   obviously wrong is not its length but that it **ends mid-sentence**, so
    ///   that is what gets tested. See `endsMidSentence`.
    static let longFormMinWords = 120
    static let longFormMinRetention = 0.75
    static let longFormMaxExpansion = 1.25

    /// A generation that hit its token ceiling stops wherever it happened to be —
    /// "…and we were 3 versions behind training. We". Detecting *that* is precise,
    /// where a length ratio is a guess.
    ///
    /// **Self-calibrating, because not every register punctuates.** S1-mini's
    /// `casual` and `semi-casual` styling deliberately omit the final period, so a
    /// missing terminator is only evidence of truncation when the model was
    /// punctuating in the first place — which the presence of terminators earlier
    /// in the output proves. An unpunctuated casual output is exempt rather than
    /// silently rejected.
    static func endsMidSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        let terminators: Set<Character> = [".", "!", "?", "\"", ")", ":", "”"]
        guard !terminators.contains(last) else { return false }
        // Did it punctuate anywhere else? If not, this is a register that omits
        // the final stop, not a cut-off generation.
        return trimmed.dropLast().contains { $0 == "." || $0 == "!" || $0 == "?" }
    }

    /// Why a rewrite was refused — or that it wasn't.
    ///
    /// The guard used to answer only `Bool`, and the reason died at the `return
    /// false`. That was fine while the only consumer was "keep the deterministic
    /// text", and it is not fine now that the Traces surface has to tell a user *why*
    /// their Smart cleanup appears to do nothing: "the model rewrote it and we threw
    /// the rewrite away because it invented a word you never said" is the answer, and
    /// it was being computed and discarded.
    ///
    /// `accept` is the same predicate it always was, expressed over this.
    enum Verdict: Equatable, Sendable {
        case accepted
        case empty
        case codeFence
        /// Longer than a faithful cleanup ever is — the tell for a model that started
        /// answering. Carries the observed ratio and the ceiling it broke.
        case tooLong(ratio: Double, ceiling: Double)
        case tooShort(ratio: Double, floor: Double)
        /// A long rewrite that stops mid-sentence: the generation hit its token
        /// ceiling. Length alone cannot separate this from a faithful pass.
        case cutOff
        /// Words in, only numbers and symbols out: the model computed the utterance.
        case computed
        /// A named entity the input never had (polish mode's anti-answer rule).
        case inventedEntity
        /// Most of the output is content the input never had (polish mode).
        case mostlyNovel(fraction: Double, ceiling: Double)
        /// A content word that traces to nothing in the input, or one repeated more
        /// often than it was said (strict mode).
        case inventedWord(String)

        var isAccepted: Bool { self == .accepted }

        /// One line for a person, not a log. Read on the Traces surface.
        var reason: String {
            switch self {
            case .accepted: return "The rewrite was faithful, so it was used."
            case .empty: return "The model returned nothing."
            case .codeFence: return "The model returned a code block, not a sentence."
            case .tooLong(let ratio, let ceiling):
                return String(format: "The rewrite was %.1f× longer than what you said (limit %.1f×) — the model started answering rather than cleaning.", ratio, ceiling)
            case .tooShort(let ratio, let floor):
                return String(format: "The rewrite kept only %.0f%% of what you said (floor %.0f%%) — too much was dropped.", ratio * 100, floor * 100)
            case .cutOff:
                return "The rewrite stopped in the middle of a sentence, so the ending would have been lost."
            case .computed:
                return "The rewrite was only numbers and symbols — the model worked the sentence out instead of cleaning it."
            case .inventedEntity:
                return "The rewrite introduced a name you didn't say — the tell for answering a question."
            case .mostlyNovel(let fraction, let ceiling):
                return String(format: "%.0f%% of the rewrite was content you never said (limit %.0f%%) — the model expanded rather than polished.", fraction * 100, ceiling * 100)
            case .inventedWord(let word):
                return "The rewrite added a word you didn't say (\u{201C}\(word)\u{201D})."
            }
        }
    }

    /// Returns `true` when `cleaned` is a plausibly faithful cleanup of
    /// `original`, `false` when the caller should discard it and keep `original`.
    /// `allowRephrase` loosens the content check for the "Polish my English" mode,
    /// which legitimately rewrites wording rather than only trimming disfluencies.
    static func accept(original: String, cleaned: String, allowRephrase: Bool = false) -> Bool {
        verdict(original: original, cleaned: cleaned, allowRephrase: allowRephrase).isAccepted
    }

    /// The same decision as `accept`, with the reason kept. Checks run in the same
    /// order they always did, so the verdict a given pair produces is the branch that
    /// used to `return false`.
    static func verdict(original: String,
                        cleaned: String,
                        allowRephrase: Bool = false) -> Verdict {
        let out = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return .empty }

        // Code fences / obvious code blocks are never a cleaned sentence.
        if out.contains("```") { return .codeFence }

        let inputWords = wordCount(original)
        let outputWords = wordCount(out)

        // Length band (loose — see doc comment).
        if inputWords > 0 {
            let ratio = Double(outputWords) / Double(inputWords)
            // Long inputs get the tight band; short ones keep the loose one they
            // were tuned against. See `longFormMinWords`.
            let isLongForm = inputWords >= longFormMinWords
            let ceiling = isLongForm
                ? longFormMaxExpansion
                : (allowRephrase ? rephraseMaxExpansionRatio : maxExpansionRatio)
            if ratio > ceiling { return .tooLong(ratio: ratio, ceiling: ceiling) }
            let floor = isLongForm ? longFormMinRetention : minRetentionRatio
            if inputWords >= truncationFloorMinWords, ratio < floor {
                return .tooShort(ratio: ratio, floor: floor)
            }
            // The tail check, which no ratio can stand in for. Long-form only: a
            // short utterance ending without a stop is ordinary.
            if isLongForm, endsMidSentence(out) { return .cutOff }
        }

        // A cleanup of a sentence with real (non-number) words always yields
        // words. If the input has content words but the output is only numbers /
        // symbols — "15 * 12 = 180", "1 2 3 4 5" — the model computed or executed
        // the utterance instead of cleaning it.
        if !contentTokens(original).isEmpty, contentTokens(out).isEmpty { return .computed }

        let outputStems = contentTokens(out).map(stem)

        if allowRephrase {
            let inputStems = Set(alphabeticTokens(original).map(stem))
            // Anti-answer rule: a mid-sentence capitalized word the input never had
            // is a named entity the model *introduced* — the tell for answering a
            // question ("capital of france" → "…is Paris"). Sentence-initial caps
            // are exempt (legitimate). This catches the short answers the
            // novel-fraction cap below can't (1 new word out of 3 slips under it).
            if introducesForeignEntity(output: out, inputStems: inputStems) { return .inventedEntity }

            // Rephrasing adds synonyms/connectives, so exact containment is too
            // strict. Reject only when MOST of the output is content the input
            // never had — the tell for expanding rather than polishing.
            guard !outputStems.isEmpty else { return .accepted }
            let novel = outputStems.filter { !inputStems.contains($0) }.count
            let fraction = Double(novel) / Double(outputStems.count)
            return fraction <= rephraseMaxNovelContentFraction
                ? .accepted
                : .mostlyNovel(fraction: fraction, ceiling: rephraseMaxNovelContentFraction)
        }

        // Strict mode: a faithful cleanup only removes / reorders / reformats — it
        // never introduces a content word the input didn't have, and never
        // *multiplies* one (e.g. a prompt injection echoing "pineapple pineapple
        // pineapple"). So each output content word must not occur more times than
        // it did in the input.
        var inputCounts: [String: Int] = [:]
        for stemmed in alphabeticTokens(original).map(stem) { inputCounts[stemmed, default: 0] += 1 }
        var outputCounts: [String: Int] = [:]
        for token in outputStems { outputCounts[token, default: 0] += 1 }
        // Sorted so the word named in the verdict is stable rather than whichever one
        // the dictionary happened to iterate first — a reason that changes between
        // runs for the same pair is not a reason.
        for (word, count) in outputCounts.sorted(by: { $0.key < $1.key })
        where count > (inputCounts[word] ?? 0) {
            return .inventedWord(word)
        }
        return .accepted
    }

    // MARK: - Anti-answer

    /// True if `output` contains a *mid-sentence* capitalized alphabetic word
    /// whose lowercased stem isn't in `inputStems` — an invented named entity
    /// (the signature of the model answering with a fact). Sentence-initial words
    /// are exempt (they're capitalized regardless), and words that trace to the
    /// input (spoken lowercase, capitalized on cleanup, e.g. "jane" → "Jane") are
    /// fine because their stem is in `inputStems`.
    private static func introducesForeignEntity(output: String, inputStems: Set<String>) -> Bool {
        var atSentenceStart = true
        for raw in output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let word = String(raw)
            let endsSentence = word.contains(".") || word.contains("?") || word.contains("!")
            defer { atSentenceStart = endsSentence }
            let core = word.trimmingCharacters(in: CharacterSet.letters.inverted)
            guard let first = core.first, core.count > 1, core.allSatisfy(\.isLetter) else { continue }
            let lower = core.lowercased()
            if !atSentenceStart, first.isUppercase,
               !stopwords.contains(lower), !numberWords.contains(lower),
               !inputStems.contains(stem(lower)) {
                return true
            }
        }
        return false
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
