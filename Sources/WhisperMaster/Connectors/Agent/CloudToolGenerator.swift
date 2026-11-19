import Foundation

/// Which brain answered a chord capture.
///
/// **Only the built-in model is on-device.** An endpoint the user sets is off-device
/// even at a loopback address: the address says where the socket ends, not where the
/// words go next, and a proxy on 127.0.0.1 can forward every prompt.
enum AgentTier: String, Codable, Sendable {
    case onDevice
    case endpoint

    /// What the band, the answer line and the trace call the endpoint tier.
    static let endpointLabel = "your endpoint"
}

/// The model behind an HTTP endpoint that the user set (Settings → Assistant, dev
/// builds only). **Text only.** The transcript and what the assistant reads go to the
/// endpoint; the recording never leaves this Mac.
///
/// The address and the model live in `UserDefaults` (`AppState.agentEndpoint`); the
/// API key lives in the Keychain (`apiKey()`), never in `UserDefaults`, and never in a
/// log or a trace.
struct AgentEndpoint: Codable, Equatable, Sendable {
    enum API: String, Codable, CaseIterable, Identifiable, Sendable {
        /// `POST …/chat/completions` with `tools` and `tool_calls`.
        case openAICompatible
        /// `POST …/v1/messages` with `tool_use` and `tool_result` blocks.
        case anthropic

        var id: String { rawValue }

        var label: String {
            switch self {
            case .openAICompatible: return "OpenAI-compatible"
            case .anthropic: return "Anthropic"
            }
        }

        var placeholderURL: String {
            switch self {
            case .openAICompatible: return "http://127.0.0.1:11434/v1/chat/completions"
            case .anthropic: return "https://api.anthropic.com/v1/messages"
            }
        }
    }

    var api: API = .openAICompatible
    /// The full request URL, not a base: no path is joined on.
    var url: String = ""
    var model: String = ""
    /// The `consentKey` the user agreed to in the consent sheet, or nil. A changed
    /// address or API asks again; a changed model does not, because the data goes to
    /// the same place.
    var consentedTo: String?
    /// The tray's pause item. Paused, every capture stays on this Mac.
    var paused: Bool = false

    /// https, or plain http to this Mac only: a key sent in clear text over a network
    /// is a key given away.
    var validURL: URL? { Self.validate(url) }

    var host: String { validURL?.host ?? "" }

    var consentKey: String { "\(api.rawValue) \(validURL?.absoluteString ?? "")" }

    var isConfigured: Bool {
        validURL != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var hasConsent: Bool { validURL != nil && consentedTo == consentKey }

    /// Ready to take a capture: set, agreed to, and not paused.
    var isActive: Bool { isConfigured && hasConsent && !paused }

    /// No user, password, query string or fragment either: each is a place a secret
    /// hides, and the address is shown in Settings and its host goes into traces.
    static func validate(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { return nil }
        if scheme == "https" { return url }
        return scheme == "http" && isLoopback(host) ? url : nil
    }

    static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }

    /// True when this capture must stay on the on-device tier: a password manager is
    /// in front, or secure input is on (a password field has focus somewhere). The
    /// same two rules that stop the selection read.
    ///
    /// - Parameters:
    ///   - atPress: the same check made when the chord went down. The front app can
    ///     change during the hold, so either moment keeps the capture local.
    ///   - followUpKeptLocal: the follow-up digest came from a capture that stayed
    ///     local (`FollowUpWindow.Digest.keptLocal`), and the digest goes with this run.
    static func staysLocal(frontBundleID: String?, secureInput: Bool,
                           atPress: Bool = false, followUpKeptLocal: Bool = false) -> Bool {
        if secureInput || atPress || followUpKeptLocal { return true }
        guard let id = frontBundleID?.lowercased() else { return false }
        return SelectionReader.privateApps.contains(id)
    }

    // MARK: - Persistence

    static let defaultsKey = "WhisperMaster.agentEndpoint.v1"

    /// A payload that does not decode reads as no endpoint at all, which is the
    /// closed direction: nothing is sent until the user sets it and agrees again.
    static func load(from defaults: UserDefaults = .standard) -> AgentEndpoint {
        defaults.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(AgentEndpoint.self, from: $0) } ?? AgentEndpoint()
    }

    /// An address `validate` refuses is written as empty: the field binds straight to
    /// this, and a pasted `?api-key=` or `user:pass@` must not reach the plist.
    func save(to defaults: UserDefaults = .standard) {
        var stored = self
        if Self.validate(url) == nil { stored.url = "" }
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.defaultsKey)
    }

    // MARK: - The key, in the Keychain

    /// The Keychain account for the key. The connector helper keys by UUID, so the
    /// endpoint takes a fixed one rather than a second Keychain wrapper.
    static let keychainID = UUID(uuidString: "5E1D0E6A-7C1B-4F0A-9E3D-A6E7B1C2D3F4")!
    private static let keyField = "api_key"

    static func apiKey() -> String? {
        ConnectorCredentials.load(for: keychainID)?[keyField]
    }

    static var hasAPIKey: Bool { ConnectorCredentials.exists(for: keychainID) }

    /// The one key slot was filled for `old`'s host, so a different host (or none)
    /// must not inherit it: a new provider with new consent would receive the old
    /// provider's key. A new path, model or API on the same host keeps it.
    static func keyMustGo(from old: AgentEndpoint, to new: AgentEndpoint) -> Bool {
        !old.host.isEmpty && new.host != old.host
    }

    /// Saves the key, or removes it when `key` is blank.
    @discardableResult
    static func setAPIKey(_ key: String?) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return ConnectorCredentials.delete(for: keychainID) }
        return ConnectorCredentials.save(ConnectorCredential([keyField: trimmed]), for: keychainID)
    }
}

/// What one remote run sent, for the trace: character counts, never the content.
///
/// Locked rather than actor-isolated because the generator is a `@Sendable` closure
/// that `AgentLoop` runs in a task it can walk away from.
final class EndpointSendLog: @unchecked Sendable {
    private let lock = NSLock()
    private var trace: EndpointSendTrace

    init(host: String) {
        trace = EndpointSendTrace(host: host)
    }

    /// The loop resends the whole conversation each turn, so the latest request holds
    /// everything the earlier ones did. Its counts are what left the Mac.
    func record(_ messages: [[String: String]], tools: [String]) {
        func characters(_ role: String) -> Int {
            messages.filter { $0["role"] == role }.reduce(0) { $0 + ($1["content"]?.count ?? 0) }
        }
        lock.lock()
        defer { lock.unlock() }
        trace.requests += 1
        trace.instructions = characters("system")
        trace.spoken = characters("user")
        trace.modelReplies = characters("assistant")
        trace.toolResults = characters("tool")
        trace.toolList = tools.reduce(0) { $0 + $1.count }
    }

    func recordFailure() {
        lock.lock()
        defer { lock.unlock() }
        trace.failures += 1
    }

    var snapshot: EndpointSendTrace {
        lock.lock()
        defer { lock.unlock() }
        return trace
    }
}

/// `AgentLoop.GenerateNative` over HTTP: an OpenAI-compatible chat endpoint or the
/// Anthropic Messages API.
///
/// **It rebuilds the provider's history on every turn** (`turns(from:)`), because the
/// loop's conversation is not in either provider's shape: the loop puts its own notes
/// in `system` messages in the middle of a run, and its `tool` messages carry no call
/// id. So each call this generator returned is re-read from the `<tool_call>` text the
/// loop stored, paired with the `tool` message after it under an id made from its
/// position, and every later `system` message goes as user text. The ids are positional,
/// so the same history always renders to the same bytes.
///
/// **Every failure is nil** — an HTTP error, a timeout, a body it cannot read, a
/// refusal — and the loop then ends like a spent budget, so the caller can hand the
/// capture to the on-device tier.
struct CloudToolGenerator: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let api: AgentEndpoint.API
    let url: URL
    let model: String
    /// nil or empty sends no credential header: a local model server needs none.
    let apiKey: String?
    let sent: EndpointSendLog
    /// Shorter than the loop's 30 s budget, so a hung server fails in time for the
    /// on-device tier to run.
    var timeout: TimeInterval = 20
    var transport: Transport = CloudToolGenerator.transport(session: .shared)
    /// Status and host only. Never the key, never a body.
    var log: @Sendable (String) -> Void = { Log.connectors.notice("\($0, privacy: .public)") }

    static let anthropicVersion = "2026-10-21"
    /// Answers here are one sentence; the room is for a model that reasons first.
    static let anthropicMaxTokens = 8_192

    init?(endpoint: AgentEndpoint, apiKey: String?, sent: EndpointSendLog) {
        guard let url = endpoint.validURL else { return nil }
        self.init(api: endpoint.api, url: url,
                  model: endpoint.model.trimmingCharacters(in: .whitespaces),
                  apiKey: apiKey, sent: sent)
    }

    init(api: AgentEndpoint.API, url: URL, model: String, apiKey: String?, sent: EndpointSendLog) {
        self.api = api
        self.url = url
        self.model = model
        self.apiKey = apiKey
        self.sent = sent
    }

    var generate: AgentLoop.GenerateNative {
        { messages, tools in await reply(messages, tools: tools) }
    }

    /// Every request goes through `RefuseRedirects`: a redirect would carry the key
    /// and the conversation to a host the user never agreed to. The 3xx comes back
    /// as the response, which `reply` treats like any other HTTP error.
    static func transport(session: URLSession) -> Transport {
        { request in try await session.data(for: request, delegate: RefuseRedirects()) }
    }

    final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    func reply(_ messages: [[String: String]], tools: [String]) async -> String? {
        guard let request = request(messages, tools: tools) else { return nil }
        sent.record(messages, tools: tools)
        let host = url.host ?? "the endpoint"
        do {
            let (data, response) = try await transport(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                sent.recordFailure()
                log("Agent endpoint \(host) answered HTTP \(status).")
                return nil
            }
            guard let reply = parse(data) else {
                sent.recordFailure()
                log("Agent endpoint \(host) sent a reply with no answer or tool call.")
                return nil
            }
            return reply
        } catch {
            sent.recordFailure()
            log("Agent endpoint \(host) failed: \((error as? URLError)?.code.rawValue ?? -1).")
            return nil
        }
    }

    // MARK: - The request

    func request(_ messages: [[String: String]], tools: [String]) -> URLRequest? {
        let (system, turns) = Self.turns(from: messages)
        let schemas = tools.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        var body: [String: Any] = ["model": model]
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch api {
        case .openAICompatible:
            body["messages"] = [["role": "system", "content": system]] + Self.openAIMessages(turns)
            if !schemas.isEmpty { body["tools"] = schemas }
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            body["max_tokens"] = Self.anthropicMaxTokens
            body["system"] = system
            body["messages"] = Self.anthropicMessages(turns)
            if !schemas.isEmpty {
                body["tools"] = schemas.compactMap(Self.anthropicTool)
                // The loop answers one call per turn, so one call is all it asks for.
                body["tool_choice"] = ["type": "auto", "disable_parallel_tool_use": true]
            }
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        else { return nil }
        request.httpBody = data
        return request
    }

    /// One entry of the rebuilt history, in neither provider's shape yet.
    enum Turn: Equatable {
        /// The user's words, an earlier question, or a note from the loop.
        case user(String)
        /// The model's own text: an answer, or a reply the loop rejected.
        case assistant(String)
        /// A call the loop ran. `arguments` is a JSON object, sorted.
        case call(id: String, name: String, arguments: String)
        /// The loop's tool result for the call with this id.
        case result(id: String, text: String)
    }

    /// The loop's wire messages as a system prompt and provider-neutral turns.
    ///
    /// A call becomes a structured call only when a tool result follows it. A call the
    /// loop refused (a repeat, an unknown tool) has none, and a provider rejects a call
    /// with no result, so that one stays text.
    static func turns(from messages: [[String: String]]) -> (system: String, turns: [Turn]) {
        var rest = messages[...]
        var system = ""
        if rest.first?["role"] == "system" {
            system = rest.first?["content"] ?? ""
            rest = rest.dropFirst()
        }
        let list = Array(rest)
        var turns: [Turn] = []
        var pendingID: String?
        var calls = 0
        for (index, message) in list.enumerated() {
            let text = message["content"] ?? ""
            switch message["role"] {
            case "assistant":
                if list.indices.contains(index + 1), list[index + 1]["role"] == "tool",
                   let call = parsedCall(text) {
                    calls += 1
                    let id = "call_\(calls)"
                    turns.append(.call(id: id, name: call.name, arguments: call.arguments))
                    pendingID = id
                } else {
                    turns.append(.assistant(text))
                }
            case "tool":
                if let id = pendingID {
                    turns.append(.result(id: id, text: text))
                    pendingID = nil
                } else {
                    turns.append(.user("Tool result:\n\(text)"))
                }
            // A mid-run note from the loop. Not every provider takes a system message
            // after the first one, and every provider takes user text there.
            default:
                turns.append(.user(text))
            }
        }
        return (system, turns)
    }

    /// The name and the sorted JSON arguments of the `<tool_call>` in a reply.
    static func parsedCall(_ text: String) -> (name: String, arguments: String)? {
        guard let block = NativeToolCallParser.extractToolCall(from: text),
              let object = (try? JSONSerialization.jsonObject(with: Data(block.utf8))) as? [String: Any],
              let name = object["name"] as? String, !name.isEmpty
        else { return nil }
        let arguments = (object["arguments"] as? [String: Any]) ?? [:]
        return (name, jsonString(arguments) ?? "{}")
    }

    static func openAIMessages(_ turns: [Turn]) -> [[String: Any]] {
        turns.map { turn in
            switch turn {
            case .user(let text): return ["role": "user", "content": text]
            case .assistant(let text): return ["role": "assistant", "content": text]
            case .call(let id, let name, let arguments):
                return ["role": "assistant", "content": NSNull(),
                        "tool_calls": [["id": id, "type": "function",
                                        "function": ["name": name, "arguments": arguments]]]]
            case .result(let id, let text):
                return ["role": "tool", "tool_call_id": id, "content": text]
            }
        }
    }

    /// Anthropic takes only user and assistant turns, so the loop's turns are grouped
    /// by side: a tool result and the note after it share one user message, with the
    /// `tool_result` block first, as the API requires.
    static func anthropicMessages(_ turns: [Turn]) -> [[String: Any]] {
        var messages: [(role: String, blocks: [[String: Any]])] = []
        for turn in turns {
            let role: String
            let block: [String: Any]
            switch turn {
            case .user(let text):
                role = "user"; block = ["type": "text", "text": text]
            case .assistant(let text):
                role = "assistant"; block = ["type": "text", "text": text]
            case .call(let id, let name, let arguments):
                role = "assistant"
                let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) ?? [String: Any]()
                block = ["type": "tool_use", "id": id, "name": name, "input": input]
            case .result(let id, let text):
                role = "user"; block = ["type": "tool_result", "tool_use_id": id, "content": text]
            }
            if messages.last?.role == role {
                messages[messages.count - 1].blocks.append(block)
            } else {
                messages.append((role, [block]))
            }
        }
        return messages.map { ["role": $0.role, "content": $0.blocks] }
    }

    /// `{"type":"function","function":{name,description,parameters}}` as an Anthropic
    /// tool: `{name, description, input_schema}`.
    static func anthropicTool(_ schema: [String: Any]) -> [String: Any]? {
        guard let function = schema["function"] as? [String: Any],
              let name = function["name"] as? String else { return nil }
        return ["name": name,
                "description": function["description"] as? String ?? "",
                "input_schema": function["parameters"] ?? ["type": "object"]]
    }

    // MARK: - The reply

    /// The reply in the shape `NativeToolCallParser` reads: the first call as a
    /// `<tool_call>` block, or the text. nil when there is neither.
    func parse(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        switch api {
        case .openAICompatible:
            guard let message = ((object["choices"] as? [[String: Any]])?.first)?["message"]
                    as? [String: Any] else { return nil }
            if let call = (message["tool_calls"] as? [[String: Any]])?.first,
               let function = call["function"] as? [String: Any],
               let name = function["name"] as? String {
                // `arguments` is a JSON string. One that does not parse is passed on
                // as it is, so the one validator rejects it rather than a guess running.
                let raw = function["arguments"] as? String ?? "{}"
                let arguments: Any = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? raw
                return Self.toolCallText(name: name, arguments: arguments)
            }
            return Self.nonEmpty(message["content"] as? String)
        case .anthropic:
            // A refusal has no answer to give; the on-device tier takes the capture.
            guard object["stop_reason"] as? String != "refusal",
                  let blocks = object["content"] as? [[String: Any]] else { return nil }
            if let use = blocks.first(where: { $0["type"] as? String == "tool_use" }),
               let name = use["name"] as? String {
                return Self.toolCallText(name: name, arguments: use["input"] ?? [String: Any]())
            }
            let text = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            return Self.nonEmpty(text)
        }
    }

    static func toolCallText(name: String, arguments: Any) -> String? {
        jsonString(["name": name, "arguments": arguments]).map { "<tool_call>\($0)</tool_call>" }
    }

    private static func jsonString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
