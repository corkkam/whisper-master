import Foundation

/// Pure string logic for stitching together the streaming transcriber's
/// successive partial/confirmed updates.
///
/// The engine re-emits overlapping text: a partial update can repeat words the
/// confirmed stream has already locked in, and successive confirmed updates can
/// overlap at their seam. These helpers normalize whitespace and collapse those
/// overlaps so the merged transcript reads cleanly. Stateless and deterministic
/// — extracted from the view model so the algorithm is isolated and testable.
enum TranscriptMerger {
    /// Merge a freshly confirmed chunk into the running confirmed transcript,
    /// collapsing any suffix/prefix overlap at the seam.
    static func mergedConfirmed(current currentConfirmed: String, new newConfirmed: String) -> String {
        let current = normalizedSpaces(in: currentConfirmed)
        let incoming = normalizedSpaces(in: newConfirmed)

        if current.isEmpty { return incoming }
        if incoming.isEmpty { return current }
        if incoming.hasPrefix(current) { return incoming }
        if current.hasPrefix(incoming) { return current }

        let overlap = longestSuffixPrefixOverlap(lhs: current, rhs: incoming)
        if overlap > 0 {
            let suffixStart = incoming.index(incoming.startIndex, offsetBy: overlap)
            let suffix = incoming[suffixStart...]
            return normalizedSpaces(in: current + " " + suffix)
        }

        return normalizedSpaces(in: current + " " + incoming)
    }

    /// The portion of a partial update that isn't already covered by the
    /// confirmed transcript (the live, not-yet-locked-in tail).
    static func partialRemainder(partialText: String, confirmedText: String) -> String {
        let partial = normalizedSpaces(in: partialText)
        let confirmed = normalizedSpaces(in: confirmedText)

        guard !partial.isEmpty else { return "" }
        guard !confirmed.isEmpty else { return partial }

        if partial.hasPrefix(confirmed) {
            let start = partial.index(partial.startIndex, offsetBy: confirmed.count)
            return normalizedSpaces(in: String(partial[start...]))
        }

        return partial
    }

    /// Best-effort full transcript from the streaming engine's two tracks: the
    /// accumulated `confirmed` text plus the current `volatile` window. The two
    /// are disjoint consecutive segments (each confirmation promotes the old
    /// volatile into confirmed and starts a fresh window), so a plain join —
    /// exactly what the engine's own `finish()` does — is the faithful
    /// reconstruction. Used to recover the transcript when the final decode
    /// fails or returns empty, so we never fall back to the last window alone.
    static func bestEffort(confirmed: String, volatile: String) -> String {
        [confirmed, volatile]
            .map { normalizedSpaces(in: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Collapse newlines and runs of whitespace into single spaces.
    static func normalizedSpaces(in text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Length of the longest string that is both a suffix of `lhs` and a prefix
    /// of `rhs` (character-wise), used to find the seam between two chunks.
    static func longestSuffixPrefixOverlap(lhs: String, rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        let maxOverlap = min(lhsChars.count, rhsChars.count)

        guard maxOverlap > 0 else { return 0 }

        for length in stride(from: maxOverlap, through: 1, by: -1) {
            let lhsSuffix = lhsChars.suffix(length)
            let rhsPrefix = rhsChars.prefix(length)
            if lhsSuffix.elementsEqual(rhsPrefix) {
                return length
            }
        }

        return 0
    }
}
