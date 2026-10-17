import Foundation

/// Who said a line. Known by which stream it came from, not by voice: the mic is
/// you, the call app's audio is everyone else.
enum MeetingSpeaker: String, Codable, Sendable {
    case me
    case others

    var label: String {
        switch self {
        case .me: return "You"
        case .others: return "Others"
        }
    }
}

struct MeetingSegment: Equatable, Sendable, Identifiable {
    let id = UUID()
    var speaker: MeetingSpeaker
    /// Milliseconds from the start of the meeting to when the words landed. The
    /// streaming engine confirms in ~11 s windows, so this is coarse by design.
    var atMs: Int
    var text: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.speaker == rhs.speaker && lhs.atMs == rhs.atMs && lhs.text == rhs.text
    }
}

/// The two-track meeting transcript. Pure, so the merge rules are tested
/// without audio.
struct MeetingTranscript: Equatable, Sendable {
    private(set) var segments: [MeetingSegment] = []
    /// Each track's cumulative text as last taken, as normalized words: all of it
    /// is already in `segments`. The engine re-sends the whole confirmed text on
    /// every update, and the next one is aligned against this.
    private var takenWords: [MeetingSpeaker: [String]] = [:]

    /// How many of the last taken words are matched to find the seam when the new
    /// text is not a straight continuation, and the fewest that still count.
    static let seamAnchorWords = 8
    static let seamMinimumWords = 3

    /// A mic line this close in time to a matching call line is the speakers
    /// leaking into the mic, not you repeating them. Wide, because both tracks
    /// confirm on their own ~11 s windows.
    static let echoWindowMs = 15_000
    /// Share of a mic line's words that must also be in the nearby call line.
    static let echoOverlap = 0.6

    /// Take one track's cumulative confirmed text and keep only what is new.
    mutating func ingest(confirmed: String, from speaker: MeetingSpeaker, atMs: Int) {
        let words = confirmed.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return }
        let normalized = words.map(Self.normalized)
        let start = Self.seam(in: normalized, after: takenWords[speaker] ?? [])
        takenWords[speaker] = normalized
        guard start < words.count else { return }
        let fresh = words[start...].joined(separator: " ")
        segments.append(MeetingSegment(speaker: speaker, atMs: atMs, text: fresh))
    }

    /// Where the words not yet in the transcript begin in `words`, given the
    /// cumulative text already taken.
    ///
    /// While streaming, each update is the last one with words added, so `taken`
    /// is a prefix and the answer is its length. The final text is not like that:
    /// `stop()` rebuilds it from tokens rather than from the confirmed track, so
    /// over an hour a word here and there differs, and slicing it by count either
    /// repeats the tail or drops it. When `taken` is not a prefix, the seam is
    /// where the last few taken words reappear, picking the match nearest to where
    /// it would be if nothing had changed. With no match, the count is all there is.
    static func seam(in words: [String], after taken: [String]) -> Int {
        guard !taken.isEmpty else { return 0 }
        if words.count >= taken.count, words.starts(with: taken) { return taken.count }
        for length in stride(from: min(seamAnchorWords, taken.count), through: seamMinimumWords, by: -1) {
            let anchor = taken.suffix(length)
            var best: Int?
            for end in stride(from: length, through: words.count, by: 1)
            where words[(end - length)..<end].elementsEqual(anchor) {
                if best.map({ abs(end - taken.count) < abs($0 - taken.count) }) ?? true { best = end }
            }
            if let best { return best }
        }
        return min(taken.count, words.count)
    }

    /// Case and punctuation do not make a word new: the final pass can capitalize
    /// or punctuate differently from the streaming one.
    private static func normalized(_ word: Substring) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" })
    }

    /// The transcript with echo removed: a mic line dropped when a call line
    /// within `echoWindowMs` carries most of its words.
    var cleanedSegments: [MeetingSegment] {
        let others = segments.filter { $0.speaker == .others }
        return segments.filter { segment in
            guard segment.speaker == .me else { return true }
            let mine = Self.wordSet(segment.text)
            guard mine.count >= 3 else { return true }
            return !others.contains { other in
                abs(other.atMs - segment.atMs) <= Self.echoWindowMs
                    && Double(mine.intersection(Self.wordSet(other.text)).count) / Double(mine.count)
                        >= Self.echoOverlap
            }
        }
    }

    var isEmpty: Bool { segments.isEmpty }

    var wordCount: Int {
        cleanedSegments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Plain text, one paragraph per speaker turn: "[03:12] You: …". This is what
    /// is stored as the note's local transcript and what the notes model reads.
    func rendered() -> String {
        var lines: [String] = []
        var current: (speaker: MeetingSpeaker, atMs: Int, text: String)?
        for segment in cleanedSegments {
            if let open = current, open.speaker == segment.speaker {
                current = (open.speaker, open.atMs, open.text + " " + segment.text)
            } else {
                if let open = current { lines.append(Self.line(open)) }
                current = (segment.speaker, segment.atMs, segment.text)
            }
        }
        if let open = current { lines.append(Self.line(open)) }
        return lines.joined(separator: "\n\n")
    }

    /// Text confirmed after `atMs`, for the rolling live notes.
    func rendered(after atMs: Int) -> String {
        var copy = self
        copy.segments = cleanedSegments.filter { $0.atMs > atMs }
        return copy.rendered()
    }

    static func timestamp(_ ms: Int) -> String {
        let seconds = ms / 1000
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func line(_ turn: (speaker: MeetingSpeaker, atMs: Int, text: String)) -> String {
        "[\(timestamp(turn.atMs))] \(turn.speaker.label): \(turn.text)"
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init))
    }
}
