import Foundation

/// Best-effort background push of per-day usage rollups to the dashboard.
///
/// Local-first: the on-device `UsageStore` is always the source of truth and the
/// dashboard renders straight off it. This client only mirrors *changed* days
/// (`UsageStore.dirtyDays`) up to the cloud for backup / cross-device, attributed
/// to the signed-in account. It never blocks dictation or the UI, is single-
/// flight and debounced, and on any failure simply leaves the days dirty to retry
/// on a later tick.
///
/// Deliberately Clerk-free — the App layer injects the identity (user id + a
/// fresh session token) via `IdentityProvider`, keeping auth out of the usage
/// layer (mirrors how `DictationViewModel` stays Clerk-free).
@MainActor
final class UsageSyncClient {
    /// Returns the signed-in user id and a fresh bearer token, or nil when not
    /// signed in / not configured.
    typealias IdentityProvider = () async -> (userId: String, token: String?)?

    private let store: UsageStore
    private let identity: IdentityProvider
    private let endpoint: URL?
    private let session: URLSession

    private var inFlight = false
    private var lastSyncAt: Date?
    /// Debounce so the 0.5 s AppDelegate tick can call this freely.
    private let minInterval: TimeInterval = 20

    init(
        store: UsageStore,
        identity: @escaping IdentityProvider,
        endpoint: URL? = UsageSyncConfig.endpoint,
        session: URLSession = .shared
    ) {
        self.store = store
        self.identity = identity
        self.endpoint = endpoint
        self.session = session
    }

    /// Debounced, single-flight trigger — safe to call on every refresh tick.
    /// No-ops when sync is disabled, nothing changed, or a push is in flight.
    func syncIfNeeded(enabled: Bool) {
        guard enabled, endpoint != nil, !inFlight else { return }
        guard !store.dirtyDays.isEmpty else { return }
        if let last = lastSyncAt, Date().timeIntervalSince(last) < minInterval { return }
        let days = store.dirtyDays
        inFlight = true
        Task { await self.push(days: days) }
    }

    private func push(days: Set<String>) async {
        defer { inFlight = false; lastSyncAt = Date() }
        guard let endpoint, let id = await identity() else { return }
        let rollups = store.rollups(for: days)
        guard !rollups.isEmpty else { store.clearDirty(days); return }

        let payload = SyncPayload(userId: id.userId, days: rollups.map(DayPayload.init))
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = id.token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let shared = UsageSyncConfig.ingestToken {
                request.setValue(shared, forHTTPHeaderField: "x-ingest-token")
            }
            request.httpBody = try JSONEncoder().encode(payload)

            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.usage.error("usage sync rejected (HTTP \(code, privacy: .public)) — leaving \(days.count) day(s) dirty")
                return
            }
            store.clearDirty(daysStillMatching(rollups, of: days))
            Log.usage.notice("usage sync pushed \(rollups.count, privacy: .public) day(s)")
        } catch {
            // Offline / transient — keep the days dirty and retry on a later tick.
            Log.usage.error("usage sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The subset of `days` whose rollup is still byte-for-byte what we POSTed, so
    /// only those get their dirty flag cleared.
    ///
    /// `UsageStore` is `@MainActor` and the finalize in `stopRecording` interleaves
    /// on that same actor, so a dictation can land *during* the request: it folds
    /// into the day and re-dirties it, and clearing the flag on the stale
    /// pre-request day set then threw that increment away — never uploaded, never
    /// retried. A day that moved stays dirty and goes up on the next tick. A day in
    /// `days` with no rollup at all (nil then and now) is still cleared, so a stray
    /// key can't pin the dirty set open forever.
    func daysStillMatching(_ sent: [DailyRollup], of days: Set<String>) -> Set<String> {
        let posted = Dictionary(sent.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let current = Dictionary(store.rollups(for: days).map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        return days.filter { posted[$0] == current[$0] }
    }

    // MARK: - Wire payload (matches the dashboard's /api/usage schema)

    private struct SyncPayload: Encodable {
        let userId: String
        let days: [DayPayload]
    }

    private struct DayPayload: Encodable {
        let day: String
        let words: Int
        let dictations: Int
        let durationSeconds: Double
        let fixesWordsCorrected: Int
        let fixesDictionary: Int
        let perApp: [String: AppUsage]

        init(_ r: DailyRollup) {
            day = r.day
            words = r.words
            dictations = r.dictations
            durationSeconds = r.durationSeconds
            fixesWordsCorrected = r.fixes.wordsCorrected
            fixesDictionary = r.fixes.dictionary
            perApp = r.perApp
        }
    }
}
