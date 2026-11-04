import Foundation

/// Notch-client discovery for `ShedEndpoint` (the type itself lives in
/// `ShedEngine/ShedEngineSupport.swift`).
///
/// The bundled engine wins when it answers (`ShedEngineSupervisor.shared.endpoint`).
/// Otherwise the discovery order is: the Settings URL, `SHED_URL`, the installed copy on
/// 4378 (root `~/.shed/app`), then a development copy on 4379 (root `~/code/shed`, or
/// `SHED_ROOT`). Shed accepts the token only from 127.0.0.1 with a localhost Host header
/// and no proxy headers, which `URLSession` to a loopback URL satisfies.
extension ShedEndpoint {
    static let installedPort = 4378
    static let developmentPort = 4379

    static func installedRoot(home: URL) -> URL {
        home.appendingPathComponent(".shed/app")
    }

    static func developmentRoot(home: URL, env: [String: String]) -> URL {
        if let root = env["SHED_ROOT"], !root.isEmpty { return URL(fileURLWithPath: root) }
        return home.appendingPathComponent("code/shed")
    }

    static func local(port: Int, root: URL) -> ShedEndpoint {
        ShedEndpoint(
            baseURL: URL(string: "http://127.0.0.1:\(port)") ?? URL(fileURLWithPath: "/"),
            tokenFile: root.appendingPathComponent(".laya-token"))
    }

    /// `override` is the Settings field, tried before everything else.
    static func candidates(
        override: String = "",
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ShedEndpoint] {
        let installed = installedRoot(home: home)
        let development = developmentRoot(home: home, env: env)
        var found: [ShedEndpoint] = []
        for raw in [override, env["SHED_URL"] ?? ""] {
            guard let url = KunaiEndpoint.normalized(raw) else { continue }
            let root = url.port == developmentPort ? development : installed
            found.append(ShedEndpoint(baseURL: url, tokenFile: root.appendingPathComponent(".laya-token")))
        }
        found.append(.local(port: installedPort, root: installed))
        found.append(.local(port: developmentPort, root: development))
        var seen = Set<String>()
        return found.filter { seen.insert($0.baseURL.absoluteString).inserted }
    }

    func api(_ path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { return nil }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }
}

enum ShedChoiceResult: Equatable, Sendable {
    case chosen
    /// Shed answered 409: the question on the Mac changed.
    case changed
    case failed
}

enum ShedPhoneResult: Equatable, Sendable {
    case updated(ShedWire.PhoneAccess)
    case failed(String)
}

/// Everything the notch asks of Shed. A protocol so tests run without a server.
protocol ShedAPI: AgentTransport {
    var activeEndpoint: ShedEndpoint? { get async }
    func terminal(sessionID: String) async -> ShedWire.Terminal?
    func choose(sessionID: String, index: Int, label: String) async -> ShedChoiceResult
    func interrupt(sessionID: String) async -> Bool
    /// Nil when this Shed has no phone-access route (it answers 404).
    func phoneAccess() async -> ShedWire.PhoneAccess?
    func useTailscale() async -> ShedPhoneResult
    /// Nil when this Shed has no accounts route; account controls then stay hidden.
    func accounts() async -> [ShedWire.Account]?
    func events() -> AsyncStream<ShedEvent>
}

/// Best-effort like `KunaiRESTClient`: an absent Shed is normal, so calls return
/// optionals instead of throwing.
actor ShedClient: ShedAPI {
    private let candidates: [ShedEndpoint]
    private let session: URLSession
    private let streamSession: URLSession
    private(set) var isReachable = false
    private(set) var active: ShedEndpoint?

    var activeEndpoint: ShedEndpoint? { active }

    /// The supervised engine's address, nil while it is not running.
    private let engine: @Sendable () async -> ShedEndpoint?

    init(
        candidates: [ShedEndpoint] = ShedEndpoint.candidates(),
        engine: @escaping @Sendable () async -> ShedEndpoint? = {
            await MainActor.run { ShedEngineSupervisor.shared.endpoint }
        }
    ) {
        self.candidates = candidates
        self.engine = engine
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        // The event stream stays open for hours, so it gets no resource timeout.
        let stream = URLSessionConfiguration.ephemeral
        stream.timeoutIntervalForRequest = 60  // Shed writes a keep-alive every 20s
        stream.timeoutIntervalForResource = 24 * 3600
        self.streamSession = URLSession(configuration: stream)
    }

    // MARK: Sessions

    func agentSessions() async -> [AgentSession] {
        let ordered: [ShedEndpoint]
        if let supervised = await engine() { ordered = [supervised] }
        else if let current = active { ordered = [current] + candidates.filter { $0 != current } }
        else { ordered = candidates }
        for endpoint in ordered {
            guard let (status, data) = await send(endpoint, "GET", "api/sessions"),
                  status == 200,
                  let list = try? JSONDecoder().decode(ShedWire.SessionsEnvelope.self, from: data)
            else { continue }
            active = endpoint
            isReachable = true
            return list.sessions.compactMap { AgentSession(shed: $0) }
        }
        active = nil
        isReachable = false
        return []
    }

    func terminal(sessionID: String) async -> ShedWire.Terminal? {
        guard let active,
              let (status, data) = await send(active, "GET", "api/sessions/\(sessionID)/terminal"),
              status == 200
        else { return nil }
        return try? JSONDecoder().decode(ShedWire.Terminal.self, from: data)
    }

    func choose(sessionID: String, index: Int, label: String) async -> ShedChoiceResult {
        guard let active,
              let (status, _) = await send(
                active, "POST", "api/sessions/\(sessionID)/terminal",
                body: ["option": index, "label": label])
        else { return .failed }
        switch status {
        case 200..<300: return .chosen
        case 409: return .changed
        default: return .failed
        }
    }

    /// Ctrl-C into the session's terminal: stops the agent's turn.
    func interrupt(sessionID: String) async -> Bool {
        guard let active,
              let (status, _) = await send(
                active, "POST", "api/sessions/\(sessionID)/terminal", body: ["text": "\u{03}"])
        else { return false }
        return (200..<300).contains(status)
    }

    // MARK: Phone access and accounts

    func phoneAccess() async -> ShedWire.PhoneAccess? {
        guard let active,
              let (status, data) = await send(active, "GET", "api/phone-access"), status == 200
        else { return nil }
        return try? JSONDecoder().decode(ShedWire.PhoneAccess.self, from: data)
    }

    func useTailscale() async -> ShedPhoneResult {
        guard let active else { return .failed("Shed is not running.") }
        guard let (status, data) = await send(
            active, "POST", "api/phone-access", body: ["mode": "tailscale"], timeout: 30)
        else { return .failed("Shed did not answer.") }
        if status == 200, let access = try? JSONDecoder().decode(ShedWire.PhoneAccess.self, from: data) {
            return .updated(access)
        }
        struct Failure: Decodable { var error: String? }
        let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
        return .failed(message ?? "Shed could not turn on Tailscale (HTTP \(status)).")
    }

    func accounts() async -> [ShedWire.Account]? {
        guard let active,
              let (status, data) = await send(active, "GET", "api/accounts"), status == 200
        else { return nil }
        return (try? JSONDecoder().decode(ShedWire.AccountsEnvelope.self, from: data))?.accounts
    }

    // MARK: Events

    /// The server-sent event stream, line by line. Ends when the connection drops;
    /// the caller reconnects.
    nonisolated func events() -> AsyncStream<ShedEvent> {
        AsyncStream { continuation in
            let task = Task {
                let current = await self.active
                guard let endpoint = current ?? self.candidates.first,
                      var request = await self.request(endpoint, "GET", "api/events", timeout: 60)
                else { return continuation.finish() }
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                do {
                    let (bytes, response) = try await self.streamSession.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        return continuation.finish()
                    }
                    var splitter = ShedLineSplitter()
                    var parser = ShedEventParser()
                    for try await byte in bytes {
                        guard let line = splitter.feed(byte) else { continue }
                        if let event = parser.feed(line) { continuation.yield(event) }
                    }
                } catch {
                    Log.agents.debug("shed event stream ended: \(error.localizedDescription, privacy: .public)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Transport

    private func request(
        _ endpoint: ShedEndpoint, _ method: String, _ path: String,
        body: [String: Any]? = nil, timeout: TimeInterval? = nil
    ) -> URLRequest? {
        guard let url = endpoint.api(path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = endpoint.readToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let timeout { request.timeoutInterval = timeout }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func send(
        _ endpoint: ShedEndpoint, _ method: String, _ path: String,
        body: [String: Any]? = nil, timeout: TimeInterval? = nil
    ) async -> (Int, Data)? {
        guard let request = request(endpoint, method, path, body: body, timeout: timeout) else {
            return nil
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            return (http.statusCode, data)
        } catch {
            Log.agents.debug("shed request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
