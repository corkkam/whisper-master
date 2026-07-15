import Foundation

/// The one place words get counted, so the history list, diagnostics, analytics,
/// and the Insights dashboard all agree on a number. Whitespace-separated tokens
/// — the same rule the pipeline already used ad hoc in three spots.
enum WordCount {
    static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
