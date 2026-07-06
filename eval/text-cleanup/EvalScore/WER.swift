import Foundation

/// Word error rate with light normalization (lowercase, keep letters/digits/`'`).
/// Word-level Levenshtein distance over the reference length.
public enum WER {
    public static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    public static func score(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference), h = normalize(hypothesis)
        if r.isEmpty { return h.isEmpty ? 0.0 : 1.0 }
        var prev = Array(0...h.count)
        for (i, rw) in r.enumerated() {
            var cur = [i + 1]
            for (j, hw) in h.enumerated() {
                let cost = rw == hw ? 0 : 1
                cur.append(Swift.min(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}
