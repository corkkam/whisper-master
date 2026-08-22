import Foundation

/// Continuous per-row measurements that sit beside the binary keyword verdict.
///
/// Why these exist: `must_contain` rules answer "did the one thing we thought to
/// assert happen", and they are blind to everything else in the output. The
/// long-form truncation of 2026-08-21 is the case in point — a 525-word input
/// came back as 207 words with the body gone, and every keyword rule still
/// passed, because the anchors that survived were the ones the case named. These
/// metrics are the shape of the output rather than a spot check of it, so a drop,
/// a runaway rewrite, or an invented sentence shows as a number even when no rule
/// was written for it.
///
/// None of them is a pass/fail criterion on its own. A retention of 0.4 is wrong
/// for a normalizer and right for a Slack summary; the band belongs to the target,
/// not to the metric. They are reported, aggregated, and compared run to run.
public struct RowMetrics: Equatable {
    /// Output words ÷ deterministic-input words. Below 1 means content was
    /// dropped, above means it was expanded. 1.0 for a pure punctuation pass.
    public let retention: Double
    /// Word-level edit distance between the deterministic input and the final
    /// output, over the input length. 0 means the LLM changed nothing — the
    /// deterministic passes did the whole job and this case does not exercise
    /// the model at all.
    public let editRate: Double
    /// Fraction of output word types that are not in the input and are not
    /// explained by a transformation the pipeline is *supposed* to make. See
    /// `novelWords` for the exclusions; this is the quantitative reading of
    /// "did it invent something", where the guard gives only accept/reject.
    public let novelWordRate: Double
    /// The novel types themselves, so a spike is readable without a re-run.
    public let novelWords: [String]
    /// WER of the output against the case's ideal `reference`, when it has one.
    /// Diagnostic: the reference is one acceptable answer, not the only one.
    public let referenceWER: Double?
    /// LLM milliseconds ÷ input words. The honest latency figure — a 500-word
    /// case at 3 s and a six-word case at 70 ms are the same speed, and a raw
    /// median over a suite of mixed lengths hides which one moved.
    public let msPerWord: Double?
    /// Input length in words, so an aggregate can weight by size and a reader
    /// can tell a ratio computed over 6 words from one over 500.
    public let inputWords: Int

    public init(retention: Double, editRate: Double, novelWordRate: Double, novelWords: [String],
                referenceWER: Double?, msPerWord: Double?, inputWords: Int) {
        self.retention = retention; self.editRate = editRate
        self.novelWordRate = novelWordRate; self.novelWords = novelWords
        self.referenceWER = referenceWER; self.msPerWord = msPerWord
        self.inputWords = inputWords
    }
}

public enum Metrics {
    /// Measure one row against its case. `deterministic` is the LLM's input, so
    /// every ratio here is LLM-attributed: the deterministic passes have already
    /// run and their edits are not counted as the model's.
    public static func measure(evalCase: EvalCase, row: ResultRow) -> RowMetrics {
        let inWords = WER.normalize(row.deterministic ?? "")
        let outWords = WER.normalize(row.llmOutput)
        let n = Double(inWords.count)

        let retention = n == 0 ? (outWords.isEmpty ? 1.0 : Double.infinity)
                               : Double(outWords.count) / n
        let editRate = n == 0 ? (outWords.isEmpty ? 0.0 : 1.0)
                              : Double(editDistance(inWords, outWords)) / n

        let novel = novelWords(input: inWords, output: outWords)
        let novelRate = outWords.isEmpty ? 0.0
                                         : Double(novel.count) / Double(Set(outWords).count)

        var refWER: Double?
        if let ref = evalCase.reference, !ref.isEmpty {
            refWER = WER.score(reference: ref, hypothesis: row.llmOutput)
        }
        var msPerWord: Double?
        if let llm = row.latencyMs["llm"], n > 0 { msPerWord = Double(llm) / n }

        return RowMetrics(retention: retention, editRate: editRate,
                          novelWordRate: novelRate, novelWords: novel,
                          referenceWER: refWER, msPerWord: msPerWord,
                          inputWords: inWords.count)
    }

    /// Output word types absent from the input, minus the ones the pipeline is
    /// built to produce. The exclusions are the whole reason this number is
    /// usable rather than noise:
    ///
    /// 1. **Numeric tokens.** Inverse text normalization is the job — "twenty
    ///    five" becoming "25" is correct, and flagging it would light up every
    ///    number case in the suite. A digit run is never counted as invented.
    /// 2. **Assembled initialisms.** "a p i" -> "api" is also the job. A novel
    ///    token whose letters appear in the input as a consecutive run of
    ///    single characters is the same words, joined.
    /// 3. **Apostrophe variants.** "its" / "it's" differ only in punctuation the
    ///    normalizer is allowed to add.
    /// 4. **Function words.** A cleanup pass legitimately reshapes grammar —
    ///    splitting or joining a contraction, restoring a dropped article,
    ///    turning "gonna" into "going to". An invented *fact* is never a closed-
    ///    class word, so excluding them costs no detection and removes almost all
    ///    of the false positives. This is why the metric can be read directly
    ///    instead of eyeballed.
    ///
    /// What survives is content the model put there: an answer to a question it
    /// was asked to punctuate, a summary sentence, a translated phrase.
    ///
    /// Known over-count, left in the open deliberately: a **content-word**
    /// rephrase that a rephrasing target is allowed to make ("purchase" for
    /// "buy" under `polish`) reads as novel. That is why the metric is scoped to
    /// a target when it is compared, and why it is never a pass/fail gate.
    static let functionWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being", "am",
        "do", "does", "did", "not", "no", "n't", "will", "would", "shall", "should",
        "can", "could", "may", "might", "must", "have", "has", "had", "to", "of",
        "in", "on", "at", "for", "with", "by", "from", "as", "and", "or", "but",
        "if", "then", "than", "so", "that", "this", "these", "those", "it", "its",
        "i", "you", "he", "she", "they", "we", "us", "me", "him", "her", "them",
        "my", "your", "his", "their", "our", "there", "here", "up", "out", "about",
        "into", "over", "just", "going", "get", "got", "s", "t", "re", "ll", "ve", "d", "m",
        // Contractions are listed rather than derived: the negatives are
        // irregular ("won't" from "will not", "can't" from "cannot"), so no
        // elision rule covers them and a fuzzy substring test does more harm
        // than the enumeration — an earlier version excluded "paris" because it
        // contains "is".
        "don't", "doesn't", "didn't", "won't", "can't", "cannot", "isn't", "aren't",
        "wasn't", "weren't", "haven't", "hasn't", "hadn't", "couldn't", "shouldn't",
        "wouldn't", "it's", "that's", "there's", "here's", "let's", "who's", "what's",
        "i'm", "i'll", "i've", "i'd", "you're", "you'll", "you've", "you'd",
        "we're", "we'll", "we've", "we'd", "they're", "they'll", "they've", "they'd",
        "he's", "she's", "he'll", "she'll", "he'd", "she'd", "gonna", "wanna",
    ]

    public static func novelWords(input: [String], output: [String]) -> [String] {
        let inSet = Set(input)
        let inNoApostrophe = Set(input.map { $0.replacingOccurrences(of: "'", with: "") })
        // Runs of single-character input tokens, joined — "a p i" -> "api".
        var initialisms = Set<String>()
        var run = ""
        for w in input + [""] {
            if w.count == 1, w.first?.isLetter == true { run += w }
            else { if run.count > 1 { initialisms.insert(run) }; run = "" }
        }

        var seen = Set<String>(), novel: [String] = []
        for w in output where !inSet.contains(w) {
            guard seen.insert(w).inserted else { continue }
            if w.allSatisfy(\.isNumber) { continue }                                   // 1
            if initialisms.contains(w) { continue }                                     // 2
            if inNoApostrophe.contains(w.replacingOccurrences(of: "'", with: "")) { continue }  // 3
            if functionWords.contains(w) { continue }                                   // 4
            novel.append(w)
        }
        return novel
    }

    private static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        var prev = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var cur = [i + 1]
            for (j, y) in b.enumerated() {
                cur.append(Swift.min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (x == y ? 0 : 1)))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
