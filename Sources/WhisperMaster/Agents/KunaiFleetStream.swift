import Foundation

/// Every session's state, pushed rather than polled.
///
/// kunai's own web app is built on two sockets, not one per session: `/ws/fleet`
/// carries the *list* — every session, its state, what it is doing — and
/// `/ws/app/{id}` carries the conversation you are actually reading. This is the
/// first of those, and adopting it is what lets the notch know about every agent at
/// once without opening a socket for each.
///
/// **It replaces a three-second poll, and that is a correctness change, not a
/// performance one.** While the list came from a poll it was up to three seconds
/// behind the per-session socket, and the two disagreed constantly: a finished turn
/// flipped back to `running` on the next poll, a blocked agent went unnoticed for
/// seconds, and the band flickered between states that were both reading the same
/// session from different clocks. One pushed source of truth removes the window
/// those bugs lived in rather than papering over each.
///
/// The frame is deliberately the **same shape** `GET /api/sessions` returns — kunai's
/// own comment says the two are shared so "a push that showed a different shape from
/// the fetch would be a bug nobody could see" — so both paths decode into the same
/// `SessionMeta` and the REST poll stays a working fallback.
actor KunaiFleetStream {

    /// What the fleet socket says. Stats are ignored: the notch reports agents, not
    /// the machine they run on.
    enum Frame: Sendable {
        case sessions([KunaiWire.SessionMeta])
        case disconnected
    }

    private let endpoint: KunaiEndpoint
    private let session: URLSession

    private var task: URLSessionWebSocketTask?
    private var pump: Task<Void, Never>?
    private var continuation: AsyncStream<Frame>.Continuation?

    init(endpoint: KunaiEndpoint) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        // No resource timeout: this socket is meant to stay open for the life of the
        // app. The request timeout still bounds the initial handshake.
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
    }

    func connect() -> AsyncStream<Frame> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.disconnect() }
            }
            self.open()
        }
    }

    func disconnect() {
        pump?.cancel()
        pump = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
    }

    /// Whether the socket is actually up, as opposed to this object existing. The
    /// controller reads it to decide how hard the REST poll has to work.
    var isConnected: Bool { task != nil }

    private func open() {
        guard task == nil, let url = endpoint.fleetSocket() else {
            continuation?.yield(.disconnected)
            return
        }
        let socket = session.webSocketTask(with: url)
        task = socket
        socket.resume()
        pump = Task { [weak self] in await self?.receiveLoop(socket) }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard let data = Self.payload(of: message) else { continue }
                ingest(data)
            } catch {
                Log.agents.debug(
                    "kunai fleet socket closed: \(error.localizedDescription, privacy: .public)")
                task = nil
                continuation?.yield(.disconnected)
                return
            }
        }
    }

    private func ingest(_ data: Data) {
        // An unfamiliar frame — a stats push, a kind added later — must never take
        // the stream down. Only a sessions snapshot is acted on.
        guard let frame = try? JSONDecoder().decode(Wire.self, from: data) else { return }
        guard frame.t == "sessions", let sessions = frame.sessions else { return }
        continuation?.yield(.sessions(sessions))
    }

    private static func payload(of message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .string(let text): return text.data(using: .utf8)
        case .data(let data): return data
        @unknown default: return nil
        }
    }

    /// Mirrors kunai's `fleetMsg`: one field set per message, switched on `t`.
    private struct Wire: Decodable {
        let t: String
        let sessions: [KunaiWire.SessionMeta]?
    }
}

/// How often the REST session list is polled, in the two worlds the client can be
/// in. Named rather than inline so the difference is legible: the fast cadence is
/// what runs *before* the fleet socket answers, and the slow one is the heartbeat
/// that survives it — the poll's only remaining job once the push works is to
/// notice a server coming back.
enum KunaiPollCadence {
    static let live: Duration = .seconds(3)
    static let background: Duration = .seconds(20)
}
