import Foundation

/// The pure value types behind the usage dashboard. No I/O, no `@Observable` —
/// `UsageStore` owns the mutation and persistence; these just describe a
/// dictation, a per-app tally, and a day's aggregate so they can be unit-tested
/// and encoded to JSON.
///
/// **Decoding is hand-written throughout and must stay that way**, for the same
/// reason `Note`'s is: these are already on disk, and the *synthesized* `Codable`
/// treats a missing non-optional key as a decode error — so adding one bare
/// non-optional field would make every stored snapshot undecodable, and
/// `UsageStore.loadFromDisk` would come up empty on a file holding a user's whole
/// usage history. Every field added from here on gets `decodeIfPresent` with a
/// default; only a row's identity (`DictationRecord.timestamp`,
/// `DailyRollup.day`) is allowed to throw, because a row that can't be placed in
/// time is not something a default can rescue.

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

    init(wordsCorrected: Int = 0, dictionary: Int = 0) {
        self.wordsCorrected = wordsCorrected
        self.dictionary = dictionary
    }

    enum CodingKeys: String, CodingKey {
        case wordsCorrected, dictionary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wordsCorrected = try c.decodeIfPresent(Int.self, forKey: .wordsCorrected) ?? 0
        dictionary = try c.decodeIfPresent(Int.self, forKey: .dictionary) ?? 0
    }
}

/// One completed dictation, captured at stop. A bounded ring of these backs the
/// recent-WPM window; the durable truth for lifetime totals and streaks is the
/// per-day rollups below.
struct DictationRecord: Codable, Equatable {
    /// What the session turned out to be. Every session is recorded — a capture
    /// the assistant handled and one that produced nothing are both real minutes
    /// of speaking, and leaving them out makes the WPM gauge, lifetime words and
    /// the streak read low. This is what keeps them from being *counted as* typed
    /// text: a reader that only wants dictated-into-a-field usage filters on it.
    enum SessionKind: String, Codable {
        /// Ordinary dictation — the transcript was typed/pasted at the cursor.
        case dictation
        /// Chord-armed capture routed to the assistant; the paste was suppressed.
        case assistant
        /// Finished with nothing to paste (only "hmm" / a silence hallucination).
        case empty
    }

    let timestamp: Date
    let wordCount: Int
    let durationSeconds: Double
    let appName: String
    let appBundleID: String
    let engineRawValue: String
    let fixes: FixCounts
    let kind: SessionKind

    /// Words per minute, guarded against the absurd values a sub-second clip
    /// would produce (a two-word "hey there" in 0.3 s is not 400 wpm).
    var wpm: Double {
        guard durationSeconds >= 1 else { return 0 }
        return Double(wordCount) / (durationSeconds / 60)
    }

    init(
        timestamp: Date,
        wordCount: Int,
        durationSeconds: Double,
        appName: String,
        appBundleID: String,
        engineRawValue: String,
        fixes: FixCounts,
        kind: SessionKind = .dictation
    ) {
        self.timestamp = timestamp
        self.wordCount = wordCount
        self.durationSeconds = durationSeconds
        self.appName = appName
        self.appBundleID = appBundleID
        self.engineRawValue = engineRawValue
        self.fixes = fixes
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, wordCount, durationSeconds
        case appName, appBundleID, engineRawValue, fixes, kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        wordCount = try c.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? ""
        appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID) ?? ""
        engineRawValue = try c.decodeIfPresent(String.self, forKey: .engineRawValue) ?? ""
        fixes = try c.decodeIfPresent(FixCounts.self, forKey: .fixes) ?? .zero
        // Read through the raw string rather than the enum: a kind written by a
        // newer build must degrade to plain dictation, not fail the whole file.
        kind = (try c.decodeIfPresent(String.self, forKey: .kind))
            .flatMap(SessionKind.init(rawValue:)) ?? .dictation
    }
}

/// Per-app tally within a single day, keyed in the rollup by bundle id.
struct AppUsage: Codable, Equatable {
    var name: String
    var words: Int
    var count: Int

    init(name: String = "", words: Int = 0, count: Int = 0) {
        self.name = name
        self.words = words
        self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case name, words, count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
    }
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

    init(
        day: String,
        words: Int = 0,
        dictations: Int = 0,
        durationSeconds: Double = 0,
        fixes: FixCounts = .zero,
        perApp: [String: AppUsage] = [:]
    ) {
        self.day = day
        self.words = words
        self.dictations = dictations
        self.durationSeconds = durationSeconds
        self.fixes = fixes
        self.perApp = perApp
    }

    enum CodingKeys: String, CodingKey {
        case day, words, dictations, durationSeconds, fixes, perApp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        dictations = try c.decodeIfPresent(Int.self, forKey: .dictations) ?? 0
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        fixes = try c.decodeIfPresent(FixCounts.self, forKey: .fixes) ?? .zero
        perApp = try c.decodeIfPresent([String: AppUsage].self, forKey: .perApp) ?? [:]
    }
}
