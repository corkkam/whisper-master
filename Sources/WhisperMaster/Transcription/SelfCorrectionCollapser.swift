import Foundation

/// Collapses spoken self-corrections between **number values**, keeping only the
/// value the speaker settled on: "twenty five no forty dollars" → "forty
/// dollars", "three no four thirty" → "four thirty", and chains "twenty no
/// thirty no forty units" → "forty units".
///
/// Deterministic and pure — runs before `DeterministicITN` (on spoken words, not
/// digits) so the survivor is what gets formatted. It fires **only** when a
/// correction is flanked by a number run on both sides, which is what makes it
/// safe: ordinary "no"/"actually" in running speech ("there were no results",
/// "i actually think") is never touched. Name/word corrections ("call john no
/// jane") aren't number-typed and are left to the LLM prompt.
///
/// The correction itself is matched as a **run** of markers and fillers, not as
/// one fixed phrase, because that is how people actually correct themselves:
/// "twenty no no thirty no no forty" and "three no um no wait four" collapse the
/// same way "twenty no thirty" does.
enum SelfCorrectionCollapser {
    /// Two-word markers, checked before one-word so "no wait" isn't read as a
    /// bare "no" (which would strand "wait").
    private static let markers2: Set<[String]> = [
        ["no", "wait"], ["no", "actually"], ["i", "mean"], ["i", "meant"],
        ["scratch", "that"], ["or", "rather"], ["make", "that"],
    ]
    private static let markers1: Set<String> = ["no", "nope", "actually", "sorry", "rather"]

    static func collapse(_ text: String) -> String {
        collapseCounting(text).text
    }

    /// Like `collapse`, but also reports how many tokens were dropped (the
    /// discarded number runs + the correction markers) — folded into the usage
    /// dashboard's "words corrected" figure.
    static func collapseCounting(_ text: String) -> (text: String, corrections: Int) {
        let toks = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !toks.isEmpty else { return (text, 0) }

        var out: [String] = []
        var i = 0
        while i < toks.count {
            let run = numericRun(toks, at: i)
            guard run > 0 else { out.append(toks[i]); i += 1; continue }

            // Extend a correction chain: run (correction run)+ — track the last run.
            var lastStart = i, lastLen = run
            var j = i + run
            var chained = false
            while true {
                let m = correctionRunLen(toks, at: j)
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
        let joined = out.joined(separator: " ")
        return (joined, max(0, toks.count - out.count))
    }

    /// Number of consecutive spoken-number-word tokens starting at `i`.
    private static func numericRun(_ toks: [String], at i: Int) -> Int {
        var n = 0
        while i + n < toks.count, SpokenNumber.isWord(clean(toks[i + n])) { n += 1 }
        return n
    }

    /// Length of the whole correction the speaker uttered at `i`, else 0.
    ///
    /// A correction is rarely one tidy marker. People stack them ("twenty no no
    /// thirty", "three no no wait four") and put fillers in the middle ("twenty um
    /// no thirty"), so this consumes a *run* of markers and fillers rather than a
    /// single hard-coded phrase — the earlier one-marker rule left the stacked form
    /// uncollapsed, and ITN then digitised every value in it ("20 no no 30 no no
    /// 40"). Fillers alone are not a correction, so the run must carry at least one
    /// real marker.
    private static func correctionRunLen(_ toks: [String], at i: Int) -> Int {
        var n = 0
        var sawMarker = false
        while i + n < toks.count {
            if i + n + 1 < toks.count, markers2.contains([clean(toks[i + n]), clean(toks[i + n + 1])]) {
                sawMarker = true
                n += 2
            } else if markers1.contains(clean(toks[i + n])) {
                sawMarker = true
                n += 1
            } else if FillerWordFilter.isFillerWord(toks[i + n]) {
                n += 1
            } else {
                break
            }
        }
        return sawMarker ? n : 0
    }

    /// Lowercased core, stripped of surrounding punctuation, for matching.
    private static func clean(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }
}
