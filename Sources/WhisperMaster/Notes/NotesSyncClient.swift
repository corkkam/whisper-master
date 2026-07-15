import Foundation

/// Best-effort background sync of notes & reminders to the dashboard, mirroring
/// `Usage/UsageSyncClient`.
///
/// Local-first: `NotesStore` is always the source of truth. This client only
/// pushes *changed* items (`NotesStore.dirtyIDs`) up for backup, and pulls the
/// account's items down once per activation so a second Mac catches up
/// (last-writer-wins by `updatedAt`, tombstones honored — see
/// `NotesStore.mergeRemote`). It never blocks the UI, is single-flight and
/// debounced, and on any failure leaves items dirty to retry on a later tick.
///
/// Clerk-free: the App layer injects the identity (user id + fresh session
/// token) via `IdentityProvider`, keeping auth out of the notes layer.
@MainActor
final class NotesSyncClient {
    typealias IdentityProvider = () async -> (userId: String, token: String?)?

    private let store: NotesStore
    private let identity: IdentityProvider
    private let endpoint: URL?
    private let session: URLSession

    private var pushInFlight = false
    private var pullInFlight = false
    private var lastSyncAt: Date?
    /// The user id we've already pulled for, so activation pulls exactly once.
    private var pulledForUserID: String?
    private let minInterval: TimeInterval = 20

    init(
        store: NotesStore,
        identity: @escaping IdentityProvider,
        endpoint: URL? = NotesSyncConfig.endpoint,
        session: URLSession = .shared
    ) {
        self.store = store
        self.identity = identity
        self.endpoint = endpoint
        self.session = session
    }

    // MARK: - Push (debounced, single-flight — safe on every tick)

    func syncIfNeeded(enabled: Bool) {
        guard enabled, endpoint != nil, !pushInFlight else { return }
        guard !store.dirtyIDs.isEmpty else { return }
        if let last = lastSyncAt, Date().timeIntervalSince(last) < minInterval { return }
        let ids = store.dirtyIDs
        pushInFlight = true
        Task { await push(ids: ids) }
    }

    private func push(ids: Set<UUID>) async {
        defer { pushInFlight = false; lastSyncAt = Date() }
        guard let endpoint, let id = await identity() else { return }
        let dirty = store.dirtyItems()
        guard !dirty.notes.isEmpty || !dirty.reminders.isEmpty else { store.clearDirty(ids); return }

        let payload = Payload(userId: id.userId, notes: dirty.notes, reminders: dirty.reminders)
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = id.token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let shared = NotesSyncConfig.ingestToken {
                request.setValue(shared, forHTTPHeaderField: "x-ingest-token")
            }
            request.httpBody = try Self.encoder.encode(payload)

            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.notes.error("notes sync rejected (HTTP \(code, privacy: .public)) — leaving \(ids.count) item(s) dirty")
                return
            }
            store.clearDirty(ids)
            Log.notes.notice("notes sync pushed \(dirty.notes.count + dirty.reminders.count, privacy: .public) item(s)")
        } catch {
            Log.notes.error("notes sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Pull (once per activation)

    /// Pull the account's items and merge them locally. Idempotent per user id —
    /// runs once per `activate`, so it's safe to call on the reconcile tick.
    func pullIfNeeded(enabled: Bool) {
        guard enabled, endpoint != nil, !pullInFlight else { return }
        guard let userID = store.currentUserID, userID != pulledForUserID else { return }
        pullInFlight = true
        Task { await pull(expectedUserID: userID) }
    }

    private func pull(expectedUserID: String) async {
        defer { pullInFlight = false }
        guard let endpoint, let id = await identity() else { return }
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            if let token = id.token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let shared = NotesSyncConfig.ingestToken {
                request.setValue(shared, forHTTPHeaderField: "x-ingest-token")
                // Shared-token mode identifies the user via query param.
                request.url = endpoint.appending(queryItems: [URLQueryItem(name: "userId", value: id.userId)])
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.notes.error("notes pull rejected (HTTP \(code, privacy: .public))")
                return
            }
            let pulled = try Self.decoder.decode(PullResponse.self, from: data)
            // Guard against a late response for a since-changed account.
            guard store.currentUserID == expectedUserID else { return }
            store.mergeRemote(notes: pulled.notes, reminders: pulled.reminders)
            pulledForUserID = expectedUserID
            Log.notes.notice("notes pull merged \(pulled.notes.count + pulled.reminders.count, privacy: .public) item(s)")
        } catch {
            Log.notes.error("notes pull failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Wire format (matches the dashboard's /api/notes schema)

    private struct Payload: Encodable {
        let userId: String
        let notes: [Note]
        let reminders: [ReminderItem]
    }

    private struct PullResponse: Decodable {
        let notes: [Note]
        let reminders: [ReminderItem]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
