import Foundation

/// The friendly lines a gentle reminder can show in the notch.
///
/// Minimal, lowercase-casual, no emoji — short enough to fit the notch band.
/// Kept apart from the policy/scheduler so copy is trivial to tweak.
enum ReminderCopy {
    static let lines: [String] = [
        "still here when you need me",
        "got something to say? i'm listening",
        "psst — i can type that for you",
        "ready whenever you are",
        "miss me? i'm one shortcut away"
    ]

    /// Pick the next line by rotating past `lastIndex`, so the same line never
    /// shows twice in a row. Returns the chosen line and its index (to remember).
    static func next(after lastIndex: Int?) -> (line: String, index: Int) {
        guard !lines.isEmpty else { return ("", 0) }
        let index: Int
        if let last = lastIndex, lines.indices.contains(last) {
            index = (last + 1) % lines.count
        } else {
            index = 0
        }
        return (lines[index], index)
    }
}
