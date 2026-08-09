import Foundation

/// The live half of the kunai client: one WebSocket per attached session.
///
/// The notch attaches to **one** session at a time — the one being read — and drops
/// the socket when the panel closes. That is what `?since=` is for: kunai keeps a
/// per-session ring buffer, so reattaching asks for everything after the last
/// sequence seen instead of replaying the conversation.
///
/// The epoch rule is the load-bearing part. `epoch` identifies the *process* behind
/// a session id and changes on every respawn, and the replacement numbers its events
/// from 1 again. A client that kept its high-water mark across a respawn would
/// discard the entire new conversation as already-seen, so a changed epoch has to
/// drop the resume mark and rebuild. That is `Frame.reset`, emitted before the
/// events that follow it.
actor KunaiEventStream {

    /// What the consumer sees. `reset` is not an error: it is the epoch rule firing,
    /// and it means "throw away what you have, the rest of this stream replaces it".
    enum Frame: Sendable {
        case reset
        case event(KunaiWire.Event)
        case disconnected
    }

    private let endpoint: KunaiEndpoint
    private let sessionID: String
    private let session: URLSession

    private var task: URLSessionWebSocketTask?
    private var pump: Task<Void, Never>?
    private var continuation: AsyncStream<Frame>.Continuation?

    /// The resume mark and the process it belongs to. Both are only meaningful
    /// together, which is why they live side by side and are cleared together.
    private var since: UInt64 = 0
    private var epoch: String?

    init(endpoint: KunaiEndpoint = .resolved, sessionID: String) {
        self.endpoint = endpoint
        self.sessionID = sessionID
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        // No resource timeout: this socket is meant to stay open for as long as the
        // panel is. The request timeout still bounds the initial handshake.
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
    }

    /// Attach and start receiving. Calling this while already attached is a no-op
    /// rather than a second socket.
    func connect() -> AsyncStream<Frame> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.disconnect() }
            }
            self.open()
        }
    }

    /// Send one command. Silently dropped when not attached: a command with no
    /// socket has nowhere to go, and the caller's alternative is to do nothing
    /// anyway.
    func send(_ command: KunaiWire.Command) async {
        guard let task, let data = try? JSONEncoder().encode(command),
              let text = String(data: data, encoding: .utf8)
        else { return }
        do {
            try await task.send(.string(text))
        } catch {
            Log.agents.error("kunai command failed: \(error.localizedDescription, privacy: .public)")
            await handleDrop()
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

    // MARK: Socket

    private func open() {
        guard task == nil, let url = endpoint.socket(sessionID: sessionID, since: since) else {
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
                await ingest(data)
            } catch {
                Log.agents.debug(
                    "kunai socket closed: \(error.localizedDescription, privacy: .public)")
                await handleDrop()
                return
            }
        }
    }

    private static func payload(of message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .string(let text): return text.data(using: .utf8)
        case .data(let data): return data
        @unknown default: return nil
        }
    }

    private func ingest(_ data: Data) {
        guard let event = try? JSONDecoder().decode(KunaiWire.Event.self, from: data) else {
            return  // an unfamiliar frame must not take the stream down
        }

        // The epoch rule, applied before anything downstream sees the event.
        if event.kind == .hello, let incoming = event.epoch {
            if let known = epoch, known != incoming {
                since = 0
                continuation?.yield(.reset)
            }
            epoch = incoming
        }

        if event.seq > since { since = event.seq }
        continuation?.yield(.event(event))
    }

    private func handleDrop() {
        task = nil
        pump = nil
        continuation?.yield(.disconnected)
    }
}
