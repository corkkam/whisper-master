import CryptoKit
import Foundation

/// Why a request to an MCP server failed, in words the Connectors page and the model
/// can read. Fixed phrases, except `.server`, which carries the server's own error
/// text (with the token taken out).
enum MCPFailure: Error, Equatable, Sendable {
    case unreachable
    case timedOut
    case unauthorized
    case status(Int)
    case unreadable
    case tooLarge
    case server(String)

    var message: String {
        switch self {
        case .unreachable: return "The server could not be reached."
        case .timedOut: return "The server did not answer within \(Int(MCPClient.requestTimeout)) seconds."
        case .unauthorized: return "The server refused the token."
        case .status(let code): return "The server answered HTTP \(code)."
        case .unreadable: return "The server's answer was not an MCP reply."
        case .tooLarge: return "The server's answer was larger than 1 MB."
        case .server(let text): return "The server returned an error: \(text)"
        }
    }
}

/// One tool as `tools/list` returned it.
struct MCPToolDefinition: Sendable, Equatable {
    let name: String
    /// The whole definition, keys sorted: what a later listing is compared against.
    let canonical: Data

    var object: [String: Any] {
        (try? JSONSerialization.jsonObject(with: canonical)) as? [String: Any] ?? [:]
    }

    var hash: String {
        SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}

/// What `tools/call` returned: its text content, and whether the server marked it an error.
struct MCPCallResult: Sendable, Equatable {
    let text: String
    let isError: Bool
}

/// A client for one MCP server over the Streamable HTTP transport: JSON-RPC 2.0, one
/// POST per message, the answer as a JSON body or as the first matching SSE event.
///
/// Hand-written rather than the official Swift SDK: the SDK's fit with Swift 5
/// language mode and its transitive dependencies were not checked, and four methods
/// (`initialize`, `notifications/initialized`, `tools/list`, `tools/call`) are all
/// this app uses. Address rules are `AgentEndpoint.validate`'s, a redirect is never
/// followed (`CloudToolGenerator.RefuseRedirects`), and the token goes only into the
/// `Authorization` header: never into a log line, and it is taken out of any text the
/// server sends back.
actor MCPClient {
    static let requestTimeout: TimeInterval = 15
    static let maxResponseBytes = 1 << 20
    /// `tools/list` pages read before the list is taken as complete.
    // shortcut: a server with more pages than this offers only the first ones; raise it if one does.
    static let maxPages = 20
    static let protocolVersion = "2025-06-18"
    static let addressRule = "Use an https address, or http on this Mac (localhost), "
        + "with no user name, password, query or fragment."

    /// Ephemeral, and the timeout covers the whole request, not only the gap between packets.
    static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration)
    }()

    let url: URL
    private let token: String?
    private let session: URLSession
    /// Host and a fixed reason only. Never the token, never a body.
    private let log: @Sendable (String) -> Void
    private var sessionID: String?
    private var negotiatedVersion: String?
    private var connected = false
    private var nextID = 1

    init?(address: String, token: String?, session: URLSession = MCPClient.liveSession,
          log: @escaping @Sendable (String) -> Void = { Log.connectors.notice("\($0, privacy: .public)") }) {
        guard let url = AgentEndpoint.validate(address) else { return nil }
        self.url = url
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.token = trimmed.isEmpty ? nil : trimmed
        self.session = session
        self.log = log
    }

    // MARK: - The four methods

    /// Every tool the server lists, after `initialize` on first use.
    func listing() async -> Result<[MCPToolDefinition], MCPFailure> {
        await attempt {
            if !connected { try await connect() }
            var tools: [MCPToolDefinition] = []
            var cursor: String?
            for _ in 0..<Self.maxPages {
                let result = try await request("tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
                for case let tool as [String: Any] in result["tools"] as? [Any] ?? [] {
                    guard let name = tool["name"] as? String, !name.isEmpty,
                          let canonical = try? JSONSerialization.data(withJSONObject: tool, options: [.sortedKeys])
                    else { continue }
                    tools.append(MCPToolDefinition(name: name, canonical: canonical))
                }
                guard let next = result["nextCursor"] as? String, !next.isEmpty else { break }
                cursor = next
            }
            return tools
        }
    }

    /// Run one tool. `arguments` is a JSON object, already typed for the tool's schema.
    func call(_ name: String, arguments: Data) async -> Result<MCPCallResult, MCPFailure> {
        await attempt {
            if !connected { try await connect() }
            let object = (try? JSONSerialization.jsonObject(with: arguments)) ?? [String: Any]()
            let result = try await request("tools/call", params: ["name": name, "arguments": object])
            let text = (result["content"] as? [Any] ?? []).compactMap { item -> String? in
                guard let item = item as? [String: Any] else { return nil }
                let type = item["type"] as? String ?? "content"
                // Text only: anything else is named, never passed on.
                if type == "text" { return item["text"] as? String }
                return "[\(type.replacingOccurrences(of: "_", with: " "))]"
            }.joined(separator: "\n")
            return MCPCallResult(text: scrubbed(text), isError: result["isError"] as? Bool ?? false)
        }
    }

    private func connect() async throws {
        let result = try await request("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Typing.sucks",
                           "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"],
        ])
        negotiatedVersion = result["protocolVersion"] as? String
        _ = try await send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        connected = true
    }

    // MARK: - Transport

    private func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        guard let message = try await send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        else { throw MCPFailure.unreadable }
        if let error = message["error"] as? [String: Any] {
            throw MCPFailure.server(scrubbed(Self.oneLine(error["message"] as? String ?? "no message")))
        }
        guard let result = message["result"] as? [String: Any] else { throw MCPFailure.unreadable }
        return result
    }

    /// POST one message. Returns the reply for a request, nil for a notification.
    private func send(_ body: [String: Any]) async throws -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request, delegate: CloudToolGenerator.RefuseRedirects())
        defer { bytes.task.cancel() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw status == 401 || status == 403 ? MCPFailure.unauthorized : MCPFailure.status(status)
        }
        if let id = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id"), !id.isEmpty {
            sessionID = id
        }
        guard let id = body["id"] as? Int else { return nil }
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.hasPrefix("text/event-stream") {
            return try await Self.firstReply(in: bytes.lines, id: id)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maxResponseBytes { throw MCPFailure.tooLarge }
        }
        return Self.reply(data, id: id)
    }

    /// The first SSE event that answers `id`. An event's `data:` lines are joined and
    /// read once they parse, so it does not depend on blank lines between events, and
    /// any server request or notification on the stream is passed over.
    static func firstReply<Lines: AsyncSequence>(in lines: Lines, id: Int) async throws -> [String: Any]?
    where Lines.Element == String {
        var buffer = ""
        var read = 0
        for try await line in lines {
            read += line.utf8.count + 1
            if read > maxResponseBytes { throw MCPFailure.tooLarge }
            guard line.hasPrefix("data:") else {
                if line.isEmpty { buffer = "" }
                continue
            }
            var value = line.dropFirst(5)
            if value.hasPrefix(" ") { value = value.dropFirst() }
            buffer = buffer.isEmpty ? String(value) : buffer + "\n" + value
            guard let object = try? JSONSerialization.jsonObject(with: Data(buffer.utf8)) else { continue }
            buffer = ""
            if let message = object as? [String: Any], (message["id"] as? Int) == id { return message }
        }
        return nil
    }

    static func reply(_ data: Data, id: Int) -> [String: Any]? {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (message["id"] as? Int) == id else { return nil }
        return message
    }

    private func attempt<T>(_ body: () async throws -> T) async -> Result<T, MCPFailure> {
        let host = url.host ?? "the server"
        do {
            return .success(try await body())
        } catch let failure as MCPFailure {
            if case .server = failure {
                log("MCP server \(host) returned a JSON-RPC error.")
            } else {
                log("MCP server \(host) failed: \(failure.message)")
            }
            return .failure(failure)
        } catch let error as URLError where error.code == .timedOut {
            log("MCP server \(host) timed out.")
            return .failure(.timedOut)
        } catch {
            log("MCP server \(host) could not be reached: \((error as? URLError)?.code.rawValue ?? -1).")
            return .failure(.unreachable)
        }
    }

    /// The token never travels on in text the server sends back.
    private func scrubbed(_ text: String) -> String {
        guard let token else { return text }
        return text.replacingOccurrences(of: token, with: "[token]")
    }

    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
