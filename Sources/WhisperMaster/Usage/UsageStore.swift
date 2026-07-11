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

    /// When false, `record(_:)` folds into memory but never writes to disk. Set by
    /// the headless snapshot renderer so seeding believable mock data can't clobber
    /// (or get migrated into) a real per-account file.
    var persistenceEnabled = true

    init(fileURL: URL = UsageStore.defaultFileURL, load: Bool = true) {
        self.fileURL = fileURL
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
        fileURL = Self.fileURL(forUserID: userID)
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
    }

    // MARK: - Write

    /// Fold one completed dictation into today's rollup + the recent ring, mark
    /// the day dirty for sync, and persist. The only mutation entry point.
    func record(_ r: DictationRecord) {
        let key = StreakCalculator.dayKey(for: r.timestamp)
        var day = rollups[key] ?? .empty(day: key)
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
        rollups[key] = day

        recent.append(r)
        if recent.count > Self.recentLimit {
            recent.removeFirst(recent.count - Self.recentLimit)
        }

        dirtyDays.insert(key)
        persist()
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

    private struct Snapshot: Codable {
        var rollups: [String: DailyRollup]
        var recent: [DictationRecord]
        var dirtyDays: [String]
    }

    private func persist() {
        guard persistenceEnabled else { return }
        let snapshot = Snapshot(rollups: rollups, recent: recent, dirtyDays: Array(dirtyDays))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            Log.usage.error("usage persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
        rollups = snapshot.rollups
        recent = snapshot.recent
        dirtyDays = Set(snapshot.dirtyDays)
    }
}
