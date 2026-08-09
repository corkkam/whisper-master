import Foundation

/// The request/response half of the kunai client: discovery, the session list, and
/// the revert preview.
///
/// An `actor` because it is called from the main actor but must never block it, and
/// because `isReachable` is shared mutable state that the poll loop and the panel
/// both read.
///
/// **Every call is best-effort and returns an optional or an empty array.** kunai is
/// not a dependency this app can require: it may be absent, mid-update, or stopped.
/// A throwing API here would push that entirely normal condition into every call
/// site as an error to handle, when the correct behaviour is always the same —
/// show nothing.
actor KunaiRESTClient {

    /// Every address worth trying, in order. A machine can run both the stable and
    /// nightly channels, on different ports with different data directories.
    private let candidates: [KunaiEndpoint]
    private let session: URLSession

    /// Short by design. This runs on a poll while the user is doing something else,
    /// so a server that is slow to answer is indistinguishable from one that is not
    /// there, and both should cost the same nothing.
    private static let timeout: TimeInterval = 2

    init(candidates: [KunaiEndpoint] = KunaiEndpoint.candidates) {
        self.candidates = candidates.isEmpty ? [KunaiEndpoint()] : candidates
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
    }

    /// Whether a kunai answered on the last call. Starts false, so the surface is
    /// dark until something proves otherwise.
    private(set) var isReachable = false

    /// The address that last answered. The event socket has to be opened against the
    /// same one, or a machine running two channels would read its sessions from one
    /// server and try to attach to the other.
    private(set) var active: KunaiEndpoint?

    /// The live sessions, or an empty list.
    ///
    /// This doubles as the reachability probe: it is the call the poll makes anyway,
    /// so there is no separate health check adding a second request per tick. The
    /// address that worked is remembered, so the common case costs one request and
    /// only a server that has gone away pays for re-probing.
    func sessions() async -> [KunaiWire.SessionMeta] {
        let ordered: [KunaiEndpoint] =
            if let active { [active] + candidates.filter { $0 != active } } else { candidates }
        for endpoint in ordered {
            guard let url = endpoint.api("api/sessions"), let data = await get(url) else {
                continue
            }
            if active != endpoint {
                Log.agents.notice(
                    "kunai found at \(endpoint.baseURL.absoluteString, privacy: .public)")
            }
            active = endpoint
            isReachable = true
            return Self.decodeSessions(data)
        }
        active = nil
        isReachable = false
        return []
    }

    /// kunai returns a bare array; an envelope is tolerated in case that changes.
    private static func decodeSessions(_ data: Data) -> [KunaiWire.SessionMeta] {
        if let list = try? JSONDecoder().decode([KunaiWire.SessionMeta].self, from: data) {
            return list
        }
        struct Envelope: Decodable { var sessions: [KunaiWire.SessionMeta] }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.sessions ?? []
    }

    /// What a revert of this turn would actually change, asked of git rather than
    /// inferred from the turn's tool calls.
    func revertPreview(sessionID: String, seq: UInt64) async -> AgentChangeSet.RevertPreview? {
        guard let endpoint = active,
              let url = endpoint.api(
            "api/sessions/\(sessionID)/revert",
            query: [URLQueryItem(name: "seq", value: String(seq))]),
            let data = await get(url)
        else { return nil }
        return try? JSONDecoder().decode(AgentChangeSet.RevertPreview.self, from: data)
    }

    // MARK: Transport

    private func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // No Origin header: kunai refuses any request carrying a cross-site one, and
        // URLSession does not add one for a native client. Nothing to set.
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return nil }
            return data
        } catch {
            // Expected whenever kunai is not running. Logged at debug so it does not
            // fill the unified log on a machine that never installs it.
            Log.agents.debug("kunai request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
