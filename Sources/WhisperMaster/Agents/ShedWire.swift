import Foundation

/// Shed's wire shapes, and the pure functions that turn them into what the notch
/// shows. Nothing here touches the network, so every mapping is unit-testable.
enum ShedWire {

    struct SessionsEnvelope: Decodable {
        var sessions: [Session]
    }

    struct Session: Decodable, Equatable {
        var id: String
        var harness: String?
        var title: String?
        var cwd: String?
        var updatedAt: String?
        /// "history" (no process), "open" (idle), "working" or "asking".
        var liveState: String
        var tty: String?
        var permissions: String?
        var agent: AgentRef?
        /// An account id such as "claude:work". Carried, not yet shown.
        var account: String?
    }

    struct AgentRef: Decodable, Equatable {
        var id: String
        var name: String
        var enabled: Bool?
    }

    /// One element of a `status` event.
    struct StatusChange: Decodable, Equatable {
        var id: String
        var liveState: String
    }

    struct Menu: Decodable, Equatable {
        var options: [String]
        var current: Int?
    }

    struct Terminal: Decodable, Equatable {
        var tty: String?
        var text: String?
        var menu: Menu?
    }

    struct PhoneAccess: Decodable, Equatable {
        var mode: String
        var canChange: Bool?
        var tailscale: Tailscale?

        struct Tailscale: Decodable, Equatable {
            var url: String?
            var problem: String?
        }

        var isTailscale: Bool { mode == "tailscale" }
    }

    /// The accounts route is optional: while it answers 404, account controls stay hidden.
    struct AccountsEnvelope: Decodable {
        var accounts: [Account]
    }

    struct Account: Decodable, Equatable {
        var id: String
        var harness: String?
        var name: String?
        var alias: String?
        var loggedIn: Bool?
    }
}

// MARK: - Sessions

extension AgentSession {

    /// A live Shed session as the notch reads it. Nil for `history`, which has no
    /// process and so nothing to show.
    init?(shed wire: ShedWire.Session) {
        guard let state = Self.state(fromShed: wire.liveState) else { return nil }
        let cwd = wire.cwd ?? ""
        self.init(
            id: wire.id, repo: AgentSession.repoName(fromPath: cwd),
            title: wire.title ?? "", state: state)
        self.cwd = cwd
        harness = AgentHarness(wire: wire.harness)
        let name = wire.agent?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        agentName = name.isEmpty ? nil : name
    }

    static func state(fromShed liveState: String) -> KunaiWire.SessionState? {
        switch liveState {
        case "working": return .running
        case "asking": return .awaitingPermission
        case "open": return .idle
        default: return nil
        }
    }

    /// What a hover row leads with: the agent's own name, else the project.
    var displayName: String { agentName ?? repo }
}

// MARK: - Server-sent events

struct ShedEvent: Equatable, Sendable {
    var name: String
    var data: String

    /// The ids and states a `status` event carries, or nil for any other event.
    var statusChanges: [ShedWire.StatusChange]? {
        guard name == "status" else { return nil }
        return try? JSONDecoder().decode([ShedWire.StatusChange].self, from: Data(data.utf8))
    }
}

/// Reads the `text/event-stream` frames Shed's `broadcast` writes:
/// `event: <name>\ndata: <json>\n\n`, plus `retry:` and `: still here` lines.
struct ShedEventParser {
    private var name = ""
    private var data: [String] = []

    /// Feed one line, without its newline. Returns an event when a blank line
    /// closes a frame that carried data.
    mutating func feed(_ rawLine: String) -> ShedEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { name = ""; data = [] }
            guard !data.isEmpty else { return nil }
            return ShedEvent(name: name.isEmpty ? "message" : name, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "event": name = value
        case "data": data.append(value)
        default: break  // retry, id: nothing to do
        }
        return nil
    }
}

/// Splits a byte stream into lines. `URLSession.AsyncBytes.lines` swallows blank
/// lines, and a blank line is exactly what ends a server-sent event.
struct ShedLineSplitter {
    private var buffer: [UInt8] = []

    mutating func feed(_ byte: UInt8) -> String? {
        guard byte == 0x0A else { buffer.append(byte); return nil }
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }
}

// MARK: - Asks

enum ShedAsk {

    /// A `.choice` ask from the question on a session's terminal. Nil when no
    /// question is on screen.
    ///
    /// The request id is the session id: Shed has one live question per terminal, and
    /// the answer is sent to that session by index and label.
    static func make(sessionID: String, context: String, terminal: ShedWire.Terminal) -> AgentAsk? {
        guard let menu = terminal.menu, !menu.options.isEmpty else { return nil }
        let question = AgentChoice.Question(
            text: questionText(from: terminal.text ?? ""), header: nil,
            multiSelect: false, options: menu.options)
        return .choice(AgentChoice(
            requestID: sessionID, questions: [question], context: context, isShed: true))
    }

    /// The last line of the screen above the options that reads as a question.
    static func questionText(from screen: String) -> String {
        let lines = screen.split(separator: "\n").map {
            $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│╭╰─")))
        }
        let found = lines.last { $0.hasSuffix("?") && $0.count > 3 }
        let text = found ?? "Choose an option"
        return text.count > 140 ? String(text.prefix(140)) + "\u{2026}" : text
    }
}
