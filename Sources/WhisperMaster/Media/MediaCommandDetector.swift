import Foundation

/// What the user asked the music to do.
enum MediaCommand: Equatable, Sendable {
    case play
    case pause
    case next
    case previous

    /// The banner line after it is done. Short because the real confirmation is
    /// audible: the room either goes quiet or it does not.
    var confirmation: String {
        switch self {
        case .play: return "Playing"
        case .pause: return "Paused"
        case .next: return "Next track"
        case .previous: return "Previous track"
        }
    }
}

/// Reads "pause the music" out of a spoken assistant capture.
///
/// **⚠️ This is legal only downstream of the assistant chord**, in
/// `routeCommandCapture`, for the same reason `DayQueryDetector` is: that path has
/// already suppressed the paste, so the worst a wrong match can do is act oddly.
/// Run over an ordinary dictation it would eat the word "pause" out of the user's
/// sentence and type nothing — the exact failure the root `CLAUDE.md` forbids
/// inferring intent for. Do not call it from anywhere else.
///
/// The vocabulary is deliberately small and literal. A capture is a whole spoken
/// instruction, so matching is on the **entire** phrase rather than a keyword
/// hiding inside a longer sentence: "pause" is a command, "pause the deploy until I
/// have looked at it" is a note.
enum MediaCommandDetector {
    private static let phrases: [(MediaCommand, [String])] = [
        (.pause, [
            "pause", "pause it", "pause music", "pause the music", "pause the song",
            "pause the video", "pause playback", "pause the podcast",
            "stop music", "stop the music", "stop the song", "stop the video",
            "stop the podcast", "stop playing", "stop playback", "mute the music",
        ]),
        (.play, [
            "play", "play it", "play music", "play the music", "play the song",
            "play the video", "play playback", "play the podcast",
            "resume", "resume music", "resume the music", "resume the song",
            "resume the video", "resume playback", "resume the podcast",
            "unpause", "unpause the music", "continue the music", "continue playing",
            "keep playing", "start the music",
        ]),
        (.next, [
            "next track", "next song", "next tune", "skip this song", "skip the song",
            "skip this track", "skip the track", "skip this", "skip song",
            "play the next song", "play the next track",
        ]),
        (.previous, [
            "previous track", "previous song", "last song", "last track",
            "go back a song", "go back a track", "play the previous song",
            "play that again", "replay that song",
        ]),
    ]

    /// The command this capture *is*, or nil when it is anything else.
    static func detect(_ text: String) -> MediaCommand? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }
        for (command, spellings) in phrases where spellings.contains(normalized) {
            return command
        }
        return nil
    }

    /// Lowercase, unpunctuated, single-spaced — the dictation may arrive as
    /// "Pause the music." with the deterministic formatter's full stop already on it.
    private static func normalize(_ text: String) -> String {
        let stripped = text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
