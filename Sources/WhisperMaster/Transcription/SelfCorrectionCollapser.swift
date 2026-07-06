import Foundation

/// Collapses spoken self-corrections between **number values**, keeping only the
/// value the speaker settled on: "twenty five no forty dollars" → "forty
/// dollars", "three no four thirty" → "four thirty", and chains "twenty no
/// thirty no forty units" → "forty units".
///
/// Deterministic and pure — runs before `DeterministicITN` (on spoken words, not
/// digits) so the survivor is what gets formatted. It fires **only** when a
/// correction marker is flanked by a number run on both sides, which is what
/// makes it safe: ordinary "no"/"actually" in running speech ("there were no
/// results", "i actually think") is never touched. Name/word corrections
/// ("call john no jane") aren't number-typed and are left to the LLM prompt.
enum SelfCorrectionCollapser {
    /// Two-word markers, checked before one-word so "no wait" isn't read as a
    /// bare "no" (which would strand "wait").
    private static let markers2: Set<[String]> = [
        ["no", "wait"], ["no", "actually"], ["i", "mean"], ["scratch", "that"], ["or", "rather"],
    ]
    private static let markers1: Set<String> = ["no", "actually"]

    static func collapse(_ text: String) -> String {
        let toks = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !toks.isEmpty else { return text }

        var out: [String] = []
        var i = 0
        while i < toks.count {
            let run = numericRun(toks, at: i)
            guard run > 0 else { out.append(toks[i]); i += 1; continue }

            // Extend a correction chain: run (marker run)+ — track the last run.
            var lastStart = i, lastLen = run
            var j = i + run
            var chained = false
            while true {
                let m = markerLen(toks, at: j)
                guard m > 0 else { break }
                let r = numericRun(toks, at: j + m)
                guard r > 0 else { break }
                chained = true
                lastStart = j + m; lastLen = r
                j += m + r
            }

            let (start, len, nextI) = chained ? (lastStart, lastLen, j) : (i, run, i + run)
            out.append(contentsOf: toks[start..<(start + len)])
            i = nextI
        }
        return out.joined(separator: " ")
    }

    /// Number of consecutive spoken-number-word tokens starting at `i`.
    private static func numericRun(_ toks: [String], at i: Int) -> Int {
        var n = 0
        while i + n < toks.count, SpokenNumber.isWord(clean(toks[i + n])) { n += 1 }
        return n
    }

    /// Token length (1 or 2) of a correction marker at `i`, else 0.
    private static func markerLen(_ toks: [String], at i: Int) -> Int {
        guard i < toks.count else { return 0 }
        if i + 1 < toks.count, markers2.contains([clean(toks[i]), clean(toks[i + 1])]) { return 2 }
        if markers1.contains(clean(toks[i])) { return 1 }
        return 0
    }

    /// Lowercased core, stripped of surrounding punctuation, for matching.
    private static func clean(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }
}
