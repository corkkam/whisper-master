import Foundation

/// Turns a meeting transcript into notes with the on-device general model.
///
/// The model call is injected (`Generate`) so tests run without a model. Live
/// code passes `MlxCleanupService.general.generateAgent`, which has a 12 s
/// ceiling per call and a 4k-ish useful context, so a long meeting is
/// **map-reduced**: each chunk becomes bullets, then the bullets become notes.
/// A chunk whose call fails is skipped, not fatal — notes from most of a meeting
/// beat no notes.
struct MeetingNotesGenerator {
    typealias Generate = @Sendable (_ user: String, _ system: String, _ maxTokens: Int) async -> String?

    let generate: Generate

    /// Words per map chunk. Big enough that a 1 h meeting is ~12 calls, small
    /// enough that one chunk plus its answer fits well inside the timeout.
    static let chunkWords = 700

    static let chunkSystem = """
        You take meeting notes. You get part of a meeting transcript. Lines start with a \
        timestamp and a speaker ("You" is the note taker, "Others" is everyone else on the call). \
        Write 3 to 8 short bullet points with the facts, decisions, numbers, names and tasks \
        in this part. Use "- " for each bullet. Do not invent anything. No preamble.
        """

    static let reduceSystem = """
        You write the final notes for a meeting from bullet points taken during it. \
        Answer in Markdown with exactly these sections, in this order:
        ## Summary
        (2 to 4 sentences)
        ## Decisions
        (bullets, or "- None")
        ## Action items
        (bullets as "- [ ] owner: task", owner is "You" or a name from the notes, or "- None")
        ## Key points
        (bullets)
        Use only facts from the bullets. Do not invent names, dates or numbers. No preamble.
        """

    static let liveSystem = """
        You take live meeting notes. You get the last few minutes of a meeting transcript. \
        Write 1 to 4 short bullet points with what was said that matters: facts, decisions, tasks. \
        Use "- " for each bullet. Do not invent anything. If nothing matters, answer "-". No preamble.
        """

    /// Split a rendered transcript into map chunks on turn boundaries.
    static func chunks(_ transcript: String, maxWords: Int = chunkWords) -> [String] {
        let turns = transcript.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        var chunks: [String] = []
        var current: [String] = []
        var count = 0
        for turn in turns {
            let words = turn.split(whereSeparator: \.isWhitespace).count
            if count + words > maxWords, !current.isEmpty {
                chunks.append(current.joined(separator: "\n\n"))
                current = []
                count = 0
            }
            if words > maxWords {
                // One very long turn: cut it by words so no chunk overruns.
                let all = turn.split(whereSeparator: \.isWhitespace)
                for start in stride(from: 0, to: all.count, by: maxWords) {
                    chunks.append(all[start..<min(start + maxWords, all.count)].joined(separator: " "))
                }
                continue
            }
            current.append(turn)
            count += words
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n\n")) }
        return chunks
    }

    /// Bullets for the last few minutes, or nil when nothing worth noting.
    func liveBullets(for recent: String) async -> String? {
        guard !recent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let raw = await generate(recent, Self.liveSystem, 200)
        else { return nil }
        let bullets = Self.bullets(in: raw)
        return bullets.isEmpty ? nil : bullets.joined(separator: "\n")
    }

    /// Final Markdown notes. `ownNotes` is what the user typed during the
    /// meeting; it is kept verbatim at the end, never rewritten by the model.
    func finalNotes(transcript: String, ownNotes: String,
                    progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> String? {
        let parts = Self.chunks(transcript)
        guard !parts.isEmpty else { return nil }
        var bullets: [String] = []
        for (index, part) in parts.enumerated() {
            progress(index, parts.count + 1)
            if let raw = await generate(part, Self.chunkSystem, 320) {
                bullets.append(contentsOf: Self.bullets(in: raw))
            }
        }
        progress(parts.count, parts.count + 1)
        guard !bullets.isEmpty else { return nil }
        // Keep the reduce input inside one call's budget.
        let joined = bullets.prefix(80).joined(separator: "\n")
        let notes = await generate(joined, Self.reduceSystem, 700) ?? Self.fallbackNotes(bullets)
        return Self.appendingOwnNotes(notes, ownNotes)
    }

    static func appendingOwnNotes(_ notes: String, _ ownNotes: String) -> String {
        let own = ownNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !own.isEmpty else { return notes }
        return notes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n## My notes\n" + own
    }

    /// When the reduce call fails, the map bullets are still useful on their own.
    static func fallbackNotes(_ bullets: [String]) -> String {
        "## Key points\n" + bullets.joined(separator: "\n")
    }

    /// Lines that are bullets, normalised to "- ". Drops a lone "-".
    static func bullets(in raw: String) -> [String] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "• "] where text.hasPrefix(marker) {
                text = String(text.dropFirst(marker.count))
                return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "- " + text
            }
            return nil
        }
    }
}
