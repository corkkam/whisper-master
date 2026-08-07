import Foundation
import Observation

/// Durable, on-device usage stats — the source of truth behind the Insights
/// dashboard. The 50-entry transcript `history` is a rolling buffer that can't
/// back lifetime totals or streaks, so this keeps its own append-only per-day
/// rollups (plus a bounded ring of recent dictations for the rolling-WPM
/// window) in `Application Support/WhisperMaster/usage.json`.
///
/// `record(_:)` is the single writer, mirroring `AppState.appendHistory`. The
/// dashboard renders straight off this (local-first); `UsageSyncClient` reads
/// `dirtyDays` to push changed rollups to the cloud in the background.
@MainActor
@Observable
final class UsageStore {
    /// Per-day aggregates, keyed by local `yyyy-MM-dd`. Never trimmed.
    private(set) var rollups: [String: DailyRollup] = [:]
    /// Recent dictations, oldest→newest, capped at `recentLimit` — only used for
    /// the rolling recent-WPM figure, so a bound is fine.
    private(set) var recent: [DictationRecord] = []
    /// Days whose rollup changed since the last successful sync.
    private(set) var dirtyDays: Set<String> = []

    static let recentLimit = 500
    /// Rolling window (days) for the headline WPM number.
    static let wpmWindowDays = 30

    /// The signed-in account whose stats are currently loaded, or nil before the
    /// first sign-in / after sign-out. Every metric on this store is scoped to it.
    private(set) var currentUserID: String?

    /// Repointed by `activate(userID:)` so each account keeps its own on-disk file
    /// — usage is per-user, not device-wide (multiple people can sign into one Mac
    /// via the org flow, and each should see only their own numbers).
    private var fileURL: URL

    /// How an account id maps to its file. Injectable only so tests can redirect
    /// the per-account files into a temp dir instead of real Application Support.
    private let fileURLForUser: (String) -> URL

    /// True when the file existed but could not be read or decoded. While set,
    /// `persist()` refuses to write: the in-memory state is the empty default and
    /// the file still holds the account's whole history, so writing would trade
    /// that history for whatever landed since. Cleared by repointing the store.
    private var loadFailed = false

    /// When false, `record(_:)` folds into memory but never writes to disk. Set by
    /// the headless snapshot renderer so seeding believable mock data can't clobber
    /// (or get migrated into) a real per-account file.
    var persistenceEnabled = true

    init(
        fileURL: URL = UsageStore.defaultFileURL,
        load: Bool = true,
        fileURLForUser: @escaping (String) -> URL = UsageStore.fileURL(forUserID:)
    ) {
        self.fileURL = fileURL
        self.fileURLForUser = fileURLForUser
        if load { self.loadFromDisk() }
    }

    /// The legacy device-wide file, from before usage was scoped per-user. Still
    /// the default so unit tests and the pre-sign-in state have a valid path; the
    /// first account to sign in adopts it (see `migrateLegacyFileIfNeeded`).
    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WhisperMaster/usage.json", isDirectory: false)
    }

    /// Per-account file: `…/WhisperMaster/Usage/<userId>.json`. The id is
    /// sanitized to keep the filename safe (Clerk ids are already alphanumeric +
    /// `_`, but never trust an id straight into a path).
    nonisolated static func fileURL(forUserID userID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safe = String(userID.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return base.appendingPathComponent("WhisperMaster/Usage/\(safe).json", isDirectory: false)
    }

    // MARK: - Per-user activation

    /// Scope the store to `userID`: repoint the file and reload from disk.
    /// Idempotent — a no-op when already scoped to that account, so the 0.5 s auth
    /// reconcile tick can call it freely. Each account starts fresh; the legacy
    /// device-wide `usage.json` (which the headless snapshot renderer could once
    /// pollute with mock data) is deliberately **not** migrated in — it's left
    /// untouched on disk and simply ignored.
    func activate(userID: String) {
        guard !userID.isEmpty, userID != currentUserID else { return }
        currentUserID = userID
        fileURL = fileURLForUser(userID)
        rollups = [:]
        recent = []
        dirtyDays = []
        loadFromDisk()
    }

    /// Drop the loaded account on sign-out so the Insights dashboard doesn't show
    /// the previous user's numbers. Their file stays on disk for when they return.
    /// Idempotent.
    func deactivate() {
        guard currentUserID != nil else { return }
        currentUserID = nil
        fileURL = Self.defaultFileURL
        rollups = [:]
        recent = []
        dirtyDays = []
        loadFailed = false
    }

    // MARK: - Write

    /// Fold one completed dictation into today's rollup + the recent ring, mark
    /// the day dirty for sync, and persist. The only mutation entry point.
    func record(_ r: DictationRecord) {
        var snapshot = currentSnapshot
        Self.fold(r, into: &snapshot)
        rollups = snapshot.rollups
        recent = snapshot.recent
        dirtyDays = Set(snapshot.dirtyDays)
        persist()
    }

    /// Record a session that began while `owner` was signed in.
    ///
    /// The finalize after a stop is long (engine finish, ITN, vocabulary, an
    /// optional LLM polish, paste routing) and the loaded account is repointed
    /// underneath it by the 0.5 s auth reconcile — so by the time the record is
    /// ready, someone else can be signed in. Usage is per-account, so the words go
    /// to the account that spoke them: folded straight into that account's file
    /// when it is no longer the loaded one, and never into whoever is loaded now.
    func record(_ r: DictationRecord, owner: String?) {
        if owner == currentUserID {
            record(r)
            return
        }
        guard let owner else {
            // Nobody was signed in when the session started, so there is no
            // account to credit — and the legacy device-wide file is deliberately
            // never adopted. Drop it loudly rather than misattribute it.
            Log.usage.error("usage record dropped: session started with no signed-in account")
            return
        }
        recordIntoFile(r, userID: owner)
    }

    /// Fold a record straight into another account's file, for a session whose
    /// owner signed out (or was replaced) while the finalize was still running.
    /// One read + one write, and only ever once per dictation.
    private func recordIntoFile(_ r: DictationRecord, userID: String) {
        guard persistenceEnabled else { return }
        let url = fileURLForUser(userID)
        do {
            var snapshot = try Self.readSnapshot(at: url) ?? .empty
            Self.fold(r, into: &snapshot)
            try Self.write(snapshot, to: url)
        } catch {
            // Unreadable/undecodable: writing would replace that account's whole
            // history with this one record, which is the worse of the two losses.
            Log.usage.error(
                "usage record for a signed-out account dropped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called by the sync client after a successful push so those days stop
    /// re-uploading (they re-dirty the moment a new dictation lands).
    func clearDirty(_ days: Set<String>) {
        dirtyDays.subtract(days)
        persist()
    }

    // MARK: - Derived metrics (computed, cheap over ~1 record/day)

    var totalWords: Int { rollups.values.reduce(0) { $0 + $1.words } }
    var totalDictations: Int { rollups.values.reduce(0) { $0 + $1.dictations } }
    var totalFixes: FixCounts { rollups.values.reduce(.zero) { $0 + $1.fixes } }

    /// Words dictated today (local), straight from today's rollup.
    var wordsToday: Int { rollups[StreakCalculator.dayKey(for: Date())]?.words ?? 0 }

    /// Headline WPM: total words over total minutes across the recent window,
    /// which weights fast/slow sessions by how much was actually said.
    var recentWpm: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.wpmWindowDays, to: Date()) ?? .distantPast
        let recs = recent.filter { $0.timestamp >= cutoff && $0.durationSeconds >= 1 }
        let words = recs.reduce(0) { $0 + $1.wordCount }
        let minutes = recs.reduce(0.0) { $0 + $1.durationSeconds } / 60
        guard minutes > 0 else { return 0 }
        return Int((Double(words) / minutes).rounded())
    }

    var activeDays: Set<String> {
        Set(rollups.compactMap { $0.value.dictations > 0 ? $0.key : nil })
    }
    var currentStreak: Int { StreakCalculator.currentStreak(activeDays: activeDays, today: Date()) }
    var longestStreak: Int { StreakCalculator.longestStreak(activeDays: activeDays) }

    /// Distinct apps ever dictated into (bundle id is the identity).
    var totalAppsUsed: Int {
        var ids = Set<String>()
        for day in rollups.values { ids.formUnion(day.perApp.keys) }
        return ids.count
    }

    /// Apps sorted by lifetime words, merged across all days. Returns the top
    /// `limit`; each entry carries its share of the total (0…1) for the bars.
    func topApps(limit: Int = 6) -> [(bundleID: String, usage: AppUsage, share: Double)] {
        var merged: [String: AppUsage] = [:]
        for day in rollups.values {
            for (bid, u) in day.perApp {
                var m = merged[bid] ?? AppUsage(name: u.name, words: 0, count: 0)
                m.words += u.words
                m.count += u.count
                if !u.name.isEmpty { m.name = u.name }
                merged[bid] = m
            }
        }
        let grandTotal = max(1, merged.values.reduce(0) { $0 + $1.words })
        return merged
            .sorted { $0.value.words > $1.value.words }
            .prefix(limit)
            .map { ($0.key, $0.value, Double($0.value.words) / Double(grandTotal)) }
    }

    /// Words dictated on a given local day key (0 if none) — for the heatmap.
    func words(onDayKey key: String) -> Int { rollups[key]?.words ?? 0 }

    /// The rollups for a set of day keys — the sync payload source.
    func rollups(for days: Set<String>) -> [DailyRollup] {
        days.compactMap { rollups[$0] }
    }

    // MARK: - Persistence

    /// The stored file. Decoding is hand-written for the same reason the models'
    /// is (see `UsageModels.swift`): a field added here later must not make every
    /// existing snapshot undecodable. A payload with *none* of the keys is still a
    /// failure though — an empty object is far more likely to be a truncated or
    /// unrelated file than a real snapshot, and treating it as valid is how a
    /// user's history would get quietly replaced by an empty one.
    private struct Snapshot: Codable {
        var rollups: [String: DailyRollup]
        var recent: [DictationRecord]
        var dirtyDays: [String]

        static let empty = Snapshot(rollups: [:], recent: [], dirtyDays: [])

        init(rollups: [String: DailyRollup], recent: [DictationRecord], dirtyDays: [String]) {
            self.rollups = rollups
            self.recent = recent
            self.dirtyDays = dirtyDays
        }

        enum CodingKeys: String, CodingKey {
            case rollups, recent, dirtyDays
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard c.contains(.rollups) || c.contains(.recent) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.rollups,
                    .init(codingPath: c.codingPath, debugDescription: "not a usage snapshot"))
            }
            rollups = try c.decodeIfPresent([String: DailyRollup].self, forKey: .rollups) ?? [:]
            recent = try c.decodeIfPresent([DictationRecord].self, forKey: .recent) ?? []
            dirtyDays = try c.decodeIfPresent([String].self, forKey: .dirtyDays) ?? []
        }
    }

    private var currentSnapshot: Snapshot {
        Snapshot(rollups: rollups, recent: recent, dirtyDays: Array(dirtyDays))
    }

    /// The whole mutation, factored out of `record` so the same arithmetic serves
    /// the loaded account's in-memory state and another account's file on disk.
    private static func fold(_ r: DictationRecord, into snapshot: inout Snapshot) {
        let key = StreakCalculator.dayKey(for: r.timestamp)
        var day = snapshot.rollups[key] ?? .empty(day: key)
        day.words += r.wordCount
        day.dictations += 1
        day.durationSeconds += r.durationSeconds
        day.fixes = day.fixes + r.fixes
        if !r.appBundleID.isEmpty || !r.appName.isEmpty {
            var app = day.perApp[r.appBundleID] ?? AppUsage(name: r.appName, words: 0, count: 0)
            app.words += r.wordCount
            app.count += 1
            if !r.appName.isEmpty { app.name = r.appName }
            day.perApp[r.appBundleID] = app
        }
        snapshot.rollups[key] = day

        snapshot.recent.append(r)
        if snapshot.recent.count > recentLimit {
            snapshot.recent.removeFirst(snapshot.recent.count - recentLimit)
        }

        if !snapshot.dirtyDays.contains(key) { snapshot.dirtyDays.append(key) }
    }

    private static func write(_ snapshot: Snapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    /// `nil` when no file is there yet (a fresh account — an empty snapshot is the
    /// right answer). **Throws** when a file *is* there and can't be read or
    /// decoded, which no caller may paper over by writing an empty snapshot back.
    private static func readSnapshot(at url: URL) throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Snapshot.self, from: try Data(contentsOf: url))
    }

    private func persist() {
        guard persistenceEnabled else { return }
        guard !loadFailed else {
            Log.usage.error(
                "usage persist skipped: \(self.fileURL.lastPathComponent, privacy: .public) failed to load, so writing would discard it")
            return
        }
        do {
            try Self.write(currentSnapshot, to: fileURL)
        } catch {
            Log.usage.error("usage persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadFromDisk() {
        loadFailed = false
        do {
            guard let snapshot = try Self.readSnapshot(at: fileURL) else { return }
            rollups = snapshot.rollups
            recent = snapshot.recent
            dirtyDays = Set(snapshot.dirtyDays)
        } catch {
            // A file is there and we couldn't read it. Say so, and stay read-only:
            // silently returning here left the empty defaults in memory for the
            // next `record()` to persist over the history this was meant to load.
            Log.usage.error(
                "usage load failed for \(self.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            loadFailed = true
        }
    }
}
