import Foundation

/// The pure value types behind the usage dashboard. No I/O, no `@Observable` —
/// `UsageStore` owns the mutation and persistence; these just describe a
/// dictation, a per-app tally, and a day's aggregate so they can be unit-tested
/// and encoded to JSON.

/// Corrections the pipeline applied to one transcript, split the way the
/// dashboard shows them: `wordsCorrected` = filler removals + spoken-number
/// self-corrections; `dictionary` = glossary (custom-vocabulary) substitutions.
struct FixCounts: Codable, Equatable {
    var wordsCorrected: Int
    var dictionary: Int

    var total: Int { wordsCorrected + dictionary }

    static let zero = FixCounts(wordsCorrected: 0, dictionary: 0)

    static func + (lhs: FixCounts, rhs: FixCounts) -> FixCounts {
        FixCounts(
            wordsCorrected: lhs.wordsCorrected + rhs.wordsCorrected,
            dictionary: lhs.dictionary + rhs.dictionary)
    }
}

/// One completed dictation, captured at stop. A bounded ring of these backs the
/// recent-WPM window; the durable truth for lifetime totals and streaks is the
/// per-day rollups below.
struct DictationRecord: Codable, Equatable {
    let timestamp: Date
    let wordCount: Int
    let durationSeconds: Double
    let appName: String
    let appBundleID: String
    let engineRawValue: String
    let fixes: FixCounts

    /// Words per minute, guarded against the absurd values a sub-second clip
    /// would produce (a two-word "hey there" in 0.3 s is not 400 wpm).
    var wpm: Double {
        guard durationSeconds >= 1 else { return 0 }
        return Double(wordCount) / (durationSeconds / 60)
    }
}

/// Per-app tally within a single day, keyed in the rollup by bundle id.
struct AppUsage: Codable, Equatable {
    var name: String
    var words: Int
    var count: Int
}

/// One local calendar day's aggregate. Append-only — never trimmed — so lifetime
/// totals and streaks survive far past the 50-entry transcript history buffer.
struct DailyRollup: Codable, Equatable {
    /// Local `yyyy-MM-dd` (see `UsageStore.dayKey`).
    let day: String
    var words: Int
    var dictations: Int
    var durationSeconds: Double
    var fixes: FixCounts
    /// Keyed by bundle id.
    var perApp: [String: AppUsage]

    static func empty(day: String) -> DailyRollup {
        DailyRollup(day: day, words: 0, dictations: 0, durationSeconds: 0, fixes: .zero, perApp: [:])
    }
}
