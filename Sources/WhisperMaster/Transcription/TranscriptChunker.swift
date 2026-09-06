import Foundation

/// Splits a long transcript into model-sized pieces at sentence boundaries.
///
/// **Why this exists.** S1-mini is built for dictation-length input — its card
/// asks for single passes under roughly 1,000 tokens — and `MlxCleanupService`
/// caps a generation at 512 tokens as a runaway-decode guard. At ~1.3 English
/// tokens per word that ceiling lands around 390 words of output, so a longer
/// dictation had its cleanup cut off mid-sentence.
///
/// **And the faithfulness guard would not have caught it.** The guard rejects
/// *gross* truncation — under 30% retention — because a tighter floor rejects
/// legitimate self-corrections and compressions. A 500-word dictation truncated
/// to 390 words retains 78%, sails through, and (on the native path, which
/// refines in place) replaces text the user already watched land correctly.
/// Losing the last quarter of someone's paragraph is the worst failure this
/// pipeline can have, and it fails *silently*, which is worse.
///
/// The chunk budget is deliberately below where the ceiling bites rather than
/// at it: `MlxCleanupService` sizes its token budget as `words * 2 + 32`, so a
/// chunk of `maxWords` or fewer is never the branch that hits 512 at all. Each
/// chunk is also comfortably inside the model's recommended input length, so
/// nothing here trades one out-of-distribution input for another.
enum TranscriptChunker {
    /// Word budget per chunk. 240 is exactly the largest input for which
    /// `words * 2 + 32` stays inside the 512-token generation cap, so a chunk can
    /// never be the thing that gets truncated. It is also ~1.5 minutes of speech —
    /// a paragraph and a half, which is well within what the model was trained on.
    static let defaultMaxWords = 240

    /// The live budget. `WM_CLEANUP_CHUNK_WORDS` overrides it for eval runs — **`0`
    /// disables chunking entirely**, which is the control this had to be measured
    /// against. Reading it here rather than threading a flag through the service
    /// keeps the switch in one place and out of the shipped call sites; unset (the
    /// only state a shipped build is ever in) is the default.
    static var maxWords: Int {
        guard let raw = ProcessInfo.processInfo.environment["WM_CLEANUP_CHUNK_WORDS"],
              let value = Int(raw) else { return defaultMaxWords }
        return value
    }

    /// Whether `text` needs splitting at all. The overwhelming majority of
    /// dictations do not, and those must take the single-pass path unchanged —
    /// chunking a short transcript would spend the KV cache for nothing.
    static func needsChunking(_ text: String, maxWords: Int? = nil) -> Bool {
        let budget = maxWords ?? Self.maxWords
        guard budget > 0 else { return false }
        return wordCount(text) > budget
    }

    /// Split into chunks of at most `maxWords` words, preferring sentence
    /// boundaries.
    ///
    /// **The invariant is that no word is lost or duplicated** — joining the
    /// result with a single space reproduces the input's words in order.
    /// `TranscriptChunkerTests` asserts it over every case, because a chunker that
    /// drops a word is a worse bug than the truncation it was written to prevent.
    static func chunks(_ text: String, maxWords explicit: Int? = nil) -> [String] {
        let maxWords = explicit ?? Self.maxWords
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard needsChunking(trimmed, maxWords: maxWords) else { return [trimmed] }

        var chunks: [String] = []
        var current: [String] = []

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(current.joined(separator: " "))
            current = []
        }

        for sentence in sentences(trimmed) {
            let words = sentence.split(separator: " ").map(String.init)
            guard !words.isEmpty else { continue }

            // A single sentence over budget can't be placed whole. Rather than
            // hand the model an oversized pass, break it at word boundaries — an
            // unpunctuated 600-word ramble is exactly the input this protects, and
            // ASR does produce them.
            if words.count > maxWords {
                flush()
                for start in stride(from: 0, to: words.count, by: maxWords) {
                    let end = min(start + maxWords, words.count)
                    chunks.append(words[start..<end].joined(separator: " "))
                }
                continue
            }

            if current.count + words.count > maxWords { flush() }
            current.append(contentsOf: words)
        }
        flush()
        return chunks
    }

    // MARK: - Internals

    /// Sentence split on `.`, `?`, `!` — but **only when whitespace follows**, the
    /// same rule `AgentReplyDocument` uses. Without it "0.6b-v3", "e.g." and
    /// "support@superwhisper.com" each become a sentence boundary, and the model
    /// then gets handed half an email address.
    private static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var iterator = Array(text)
        var index = 0

        while index < iterator.count {
            let ch = iterator[index]
            current.append(ch)
            if ch == "." || ch == "?" || ch == "!" {
                let next = index + 1 < iterator.count ? iterator[index + 1] : " "
                if next.isWhitespace {
                    let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !piece.isEmpty { out.append(piece) }
                    current = ""
                }
            }
            index += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    private static func wordCount(_ text: String) -> Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }
}
