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
    /// How many words of each track's cumulative confirmed text are already in
    /// `segments`. The engine re-sends the whole confirmed text on every update.
    private var consumedWords: [MeetingSpeaker: Int] = [:]

    /// A mic line this close in time to a matching call line is the speakers
    /// leaking into the mic, not you repeating them. Wide, because both tracks
    /// confirm on their own ~11 s windows.
    static let echoWindowMs = 15_000
    /// Share of a mic line's words that must also be in the nearby call line.
    static let echoOverlap = 0.6

    /// Take one track's cumulative confirmed text and keep only what is new.
    mutating func ingest(confirmed: String, from speaker: MeetingSpeaker, atMs: Int) {
        let words = confirmed.split(whereSeparator: \.isWhitespace)
        let already = consumedWords[speaker] ?? 0
        guard words.count > already else { return }
        let fresh = words[already...].joined(separator: " ")
        consumedWords[speaker] = words.count
        segments.append(MeetingSegment(speaker: speaker, atMs: atMs, text: fresh))
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
