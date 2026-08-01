import Foundation

/// Turns an assistant answer into the sentences a synthesizer should say.
///
/// Pure and deterministic — no model, no audio — so the part of speech that can
/// actually be wrong is unit-tested (`SpokenAnswerTests`) rather than listened to.
/// Both backends share it, which is what keeps the system voice and the natural
/// voice saying the same words.
///
/// Three jobs, in order:
///
/// 1. **Sanitize.** The answer comes out of a 3B model, so it isn't guaranteed to be
///    clean prose — markdown emphasis, a bulleted list, a bare URL and the odd emoji
///    all show up, and all of them are gibberish when spoken ("star star three star
///    star meetings").
/// 2. **Chunk into sentences.** `KokoroAneManager` rejects input over 512 IPA tokens
///    ("chunk longer prompts upstream" — its own doc comment), so this is load-bearing,
///    not an optimisation. It also gives both backends their barge-in granularity and
///    lets the natural backend synthesize sentence *n+1* while *n* is playing.
/// 3. **Cap the whole thing.** An answer that runs for two minutes is a worse outcome
///    than a truncated one — the user asked a question, not for a podcast.
enum SpokenAnswer {

    /// Longest single utterance handed to a backend. Comfortably inside Kokoro's
    /// 512-IPA-token ceiling (English averages well under one token per character,
    /// but contractions and numbers expand, so this leaves real headroom).
    static let maxSentenceCharacters = 300

    /// Longest total answer we'll speak — roughly 45 seconds at a normal rate.
    /// Past this the notch banner and the Recent-answers card are the right place
    /// to read the rest.
    static let maxSpokenCharacters = 600

    /// The sentences to speak, in order. Empty when there is nothing sayable —
    /// callers treat that as "don't speak", never as an error.
    ///
    /// - Parameter detail: the banner's second line. Pass `nil` on the agent path,
    ///   where it holds provenance chrome ("From Work Calendar") that is worth
    ///   *seeing* and not worth *hearing*; pass it on the deterministic-summary
    ///   path, where it carries the actual next thing on the calendar.
    static func prepare(headline: String, detail: String? = nil) -> [String] {
        var combined = sanitize(headline)
        if let detail {
            let tail = sanitize(detail)
            if !tail.isEmpty {
                // A headline that already ends in terminal punctuation shouldn't get
                // a second one — the synthesizer reads "..." as a longer pause.
                combined = combined.isEmpty
                    ? tail
                    : combined + (endsSentence(combined) ? " " : ". ") + tail
            }
        }
        guard !combined.isEmpty else { return [] }
        return cap(split(combined))
    }

    // MARK: - Sanitize

    /// Strips everything that reads as markup rather than speech, then collapses
    /// whitespace so line breaks in the model's output don't become dead air.
    static func sanitize(_ text: String) -> String {
        var result = stripMarkdownLinks(text)
        result = stripEmoji(result)
        result = joinLines(result)
        result = stripInlineMarkup(result)
        result = replaceBareURLs(result)
        return collapseWhitespace(result)
    }

    /// Strips per-line heading and list markers, then rejoins.
    ///
    /// The join is the subtle part. A bulleted list is a set of discrete items and
    /// should be read with sentence breaks between them; a paragraph the model happened
    /// to wrap is one sentence, and inserting a full stop into the middle of it would
    /// make the voice stop dead mid-thought. So a line only earns a `". "` separator
    /// when it (or its predecessor) actually carried a marker — the one signal that
    /// distinguishes "this is its own item" from "this is where the text wrapped".
    private static func joinLines(_ text: String) -> String {
        var out = ""
        var previousWasBlock = false
        var first = true
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let (line, isBlock) = stripLeadingMarkers(rawLine)
            guard !line.isEmpty else { continue }
            if first {
                out = line
                first = false
            } else if endsSentence(out) {
                out += " " + line
            } else if isBlock || previousWasBlock {
                out += ". " + line
            } else {
                out += " " + line
            }
            previousWasBlock = isBlock
        }
        return out
    }

    /// Returns the line without its leading `#`/bullet/`1.` marker, and whether it had
    /// one. Only ever applied at the *start of a line*, which is what keeps "#1 on the
    /// list" and "the 10-4 split" intact — those markers are only markup up front.
    private static func stripLeadingMarkers(_ rawLine: Substring) -> (String, Bool) {
        var line = rawLine.drop(while: { $0.isWhitespace })
        var isBlock = false

        var hashes = 0
        while line.first == "#", hashes < 6 {
            line = line.dropFirst()
            hashes += 1
        }
        if hashes > 0, line.first?.isWhitespace == true {
            line = line.drop(while: { $0.isWhitespace })
            isBlock = true
        } else if hashes > 0 {
            // "#1 on the list" — not a heading after all, put the hashes back.
            line = rawLine.drop(while: { $0.isWhitespace })
        }

        // A bullet is a marker character *followed by a space*, so "**bold** first"
        // (whose leading `*` is emphasis) is left for the inline pass.
        if let marker = line.first, "-+•‣▪*".contains(marker),
           line.dropFirst().first?.isWhitespace == true {
            line = line.dropFirst().drop(while: { $0.isWhitespace })
            isBlock = true
        }

        // "1." / "2)" — at most two digits, so a year never reads as a list marker.
        let digits = line.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 2 {
            let afterDigits = line.dropFirst(digits.count)
            if let separator = afterDigits.first, separator == "." || separator == ")",
               afterDigits.dropFirst().first?.isWhitespace == true {
                line = afterDigits.dropFirst().drop(while: { $0.isWhitespace })
                isBlock = true
            }
        }

        return (String(line), isBlock)
    }

    /// `[text](url)` → `text`. Done first, so the URL inside never reaches the bare-URL
    /// pass and the visible label survives.
    private static func stripMarkdownLinks(_ text: String) -> String {
        guard text.contains("](") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            // Everything before the bracket is untouched.
            out += rest[rest.startIndex..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "]"),
                  rest.index(after: close) < rest.endIndex,
                  rest[rest.index(after: close)] == "(",
                  let paren = rest[rest.index(after: close)...].firstIndex(of: ")")
            else {
                // Not a link after all — keep the bracket and move past it.
                out.append("[")
                rest = rest[afterOpen...]
                continue
            }
            out += rest[afterOpen..<close]
            rest = rest[rest.index(after: paren)...]
        }
        return out + rest
    }

    /// Emphasis markers and code ticks. `_` is only dropped at a word boundary so
    /// `snake_case` survives as one word instead of becoming "snakecase". Heading and
    /// bullet markers are already gone — `joinLines` handled them where they mean
    /// something, so anything left here is ordinary text.
    private static func stripInlineMarkup(_ text: String) -> String {
        var out = ""
        var atBoundary = true          // start of string counts as a boundary
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            let followedByBoundary = next == text.endIndex || isBoundary(text[next])
            switch char {
            case "*", "`", "~":
                break                  // never spoken, wherever they appear
            case "_":
                // Emphasis only when it hugs an edge; inside a word it's part of it.
                if !(atBoundary || followedByBoundary) { out.append(char) }
            case "•", "‣", "▪":
                break
            default:
                out.append(char)
            }
            if char != "*" && char != "`" && char != "~" && char != "_" {
                atBoundary = isBoundary(char)
            }
            index = next
        }
        return out
    }

    private static func isBoundary(_ char: Character) -> Bool {
        char.isWhitespace || char.isNewline
    }

    /// A spoken URL is noise — nobody transcribes "h t t p colon slash slash" by ear.
    private static func replaceBareURLs(_ text: String) -> String {
        guard text.contains("http") || text.contains("www.") else { return text }
        let spoken = text.split(separator: " ", omittingEmptySubsequences: false).map { token -> Substring in
            let lower = token.lowercased()
            let isURL = lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.")
            return isURL ? "link" : token
        }
        return spoken.joined(separator: " ")
    }

    /// Drops emoji, the modifiers that compose them, and the zero-width joiner. The
    /// `value >= 0x1F000` floor matters: `Emoji=Yes` is also true of the ASCII digits
    /// and `#`/`*`, which we very much do want to keep.
    private static func stripEmoji(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isEmojiScalar($0) }))
    }

    private static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0xFE0F || scalar.value == 0x200D { return true }   // VS16, ZWJ
        if (0x1F1E6...0x1F1FF).contains(scalar.value) { return true }         // flags
        if (0x1F3FB...0x1F3FF).contains(scalar.value) { return true }         // skin tones
        if scalar.properties.isEmojiPresentation { return true }
        return scalar.properties.isEmoji && scalar.value >= 0x1F000
    }

    /// Runs of whitespace become one space, and a space stranded *before* punctuation
    /// is closed up. That second half matters because removing an emoji leaves a hole:
    /// "today 🎉, first at nine" would otherwise collapse to "today , first at nine",
    /// and a synthesizer pauses at that orphaned space as if it were a word.
    private static func collapseWhitespace(_ text: String) -> String {
        let single = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        var out = ""
        var pendingSpace = false
        for char in single {
            if char == " " {
                pendingSpace = true
                continue
            }
            if pendingSpace {
                if !",.;:!?".contains(char) { out.append(" ") }
                pendingSpace = false
            }
            out.append(char)
        }
        return out
    }

    // MARK: - Sentence splitting

    /// Splits on terminal punctuation followed by whitespace, then hard-chunks anything
    /// still over `maxSentenceCharacters`.
    static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            current.append(char)
            let next = text.index(after: index)
            if isTerminator(char) {
                let atEnd = next == text.endIndex
                // Requiring whitespace after is what keeps "3.5" and "example.com"
                // from being read as two sentences.
                let breaks = atEnd || text[next].isWhitespace
                if breaks && !endsWithAbbreviation(current) {
                    appendChunks(of: current, to: &sentences)
                    current = ""
                }
            }
            index = next
        }
        appendChunks(of: current, to: &sentences)
        return sentences
    }

    private static func isTerminator(_ char: Character) -> Bool {
        char == "." || char == "!" || char == "?" || char == "。"
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return isTerminator(last)
    }

    /// The abbreviations a calendar answer actually produces. Deliberately short — a
    /// missed split costs a slightly long pause, while an over-eager list would start
    /// swallowing real sentence breaks.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st",
        "e.g", "i.e", "vs", "etc", "approx", "no",
        "a.m", "p.m", "jan", "feb", "mar", "apr", "jun",
        "jul", "aug", "sep", "sept", "oct", "nov", "dec"
    ]

    private static func endsWithAbbreviation(_ text: String) -> Bool {
        guard text.hasSuffix(".") else { return false }
        let body = text.dropLast()
        let word = body.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        guard !word.isEmpty else { return false }
        // A lone initial ("J.") is never a sentence end either.
        if word.count == 1, word.first?.isUppercase == true { return true }
        return abbreviations.contains(word.lowercased())
    }

    /// Adds `sentence`, broken at the last space before the limit when it's too long
    /// for one utterance. A word with no space to break on is cut mid-word rather
    /// than dropped — a clipped word beats a thrown backend.
    private static func appendChunks(of sentence: String, to sentences: inout [String]) {
        var remaining = sentence.trimmingCharacters(in: .whitespaces)
        guard !remaining.isEmpty else { return }
        while remaining.count > maxSentenceCharacters {
            let limit = remaining.index(remaining.startIndex, offsetBy: maxSentenceCharacters)
            let breakPoint = remaining[..<limit].lastIndex(where: { $0.isWhitespace }) ?? limit
            let head = remaining[..<breakPoint].trimmingCharacters(in: .whitespaces)
            if head.isEmpty { break }
            sentences.append(head)
            remaining = remaining[breakPoint...].trimmingCharacters(in: .whitespaces)
        }
        if !remaining.isEmpty { sentences.append(remaining) }
    }

    // MARK: - Capping

    /// Keeps whole sentences up to `maxSpokenCharacters`. Always yields at least the
    /// first sentence — it's already chunked to the per-utterance limit, so there is
    /// no case where the cap leaves us with nothing to say. No spoken "…and more":
    /// the answer is on screen and in Recent answers, and an apology read aloud is
    /// worse than simply stopping.
    private static func cap(_ sentences: [String]) -> [String] {
        var kept: [String] = []
        var total = 0
        for sentence in sentences {
            if !kept.isEmpty && total + sentence.count > maxSpokenCharacters { break }
            kept.append(sentence)
            total += sentence.count + 1
        }
        return kept
    }
}
