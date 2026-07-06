import Foundation

/// Parses spoken cardinal-number words into an integer ("twenty five" → 25,
/// "one hundred twenty three" → 123, "three thousand five hundred" → 3500).
/// Pure and deterministic — the core of the rule-based formatter.
enum SpokenNumber {
    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    static func isWord(_ w: String) -> Bool { units[w] != nil || scales[w] != nil }

    /// Value of a run of number words, or `nil` if the run isn't a valid number.
    ///
    /// Adjacent unit words are only additive in one well-formed case: a tens
    /// word (20–90) followed by a ones word (1–9), e.g. "twenty five" → 25.
    /// Any other back-to-back unit words ("one two three", "five three") are
    /// a spoken sequence, not a cardinal, so the run is rejected (`nil`) rather
    /// than summed — otherwise "one two three" would collapse to 6.
    static func value(_ words: [String]) -> Int? {
        var result = 0, current = 0, used = false
        // The last unit word folded into `current` since the last scale/hundred
        // reset; `nil` means the next unit starts a fresh sub-block.
        var prevUnit: Int?
        for w in words {
            if w == "and" || w == "a" || w == "an" { continue }
            if let u = units[w] {
                if let p = prevUnit {
                    let prevIsTens = p >= 20 && p % 10 == 0
                    let uIsOnes = (1...9).contains(u)
                    guard prevIsTens && uIsOnes else { return nil }
                }
                current += u; used = true; prevUnit = u
            } else if w == "hundred" {
                current = (current == 0 ? 1 : current) * 100; used = true; prevUnit = nil
            } else if let s = scales[w] {
                result += (current == 0 ? 1 : current) * s; current = 0; used = true; prevUnit = nil
            } else {
                return nil
            }
        }
        return used ? result + current : nil
    }
}
