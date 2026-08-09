import Foundation

/// The kunai wire protocol, as much of it as the notch needs.
///
/// kunai drives one `claude` process per session over its stream-json control
/// protocol and re-publishes the result as `AppEvent` frames on
/// `GET /ws/app/{id}`. Frames are **monotonically sequenced within a session**, so
/// a client that drops off can ask for everything after the last sequence it saw
/// (`?since=N`) instead of replaying the conversation. That is exactly the shape a
/// notch panel needs: it is closed most of the time.
///
/// Only a subset of each frame is modelled here. kunai's `AppEvent` is one wide
/// struct shared by every event type (fields are omitted when empty and the client
/// dispatches on `t`), and the notch reads a fraction of it. Everything is
/// optional and decoding is deliberately lenient: **a field kunai adds later must
/// never stop an event we already understand from decoding**, because the server
/// self-updates independently of this app.
enum KunaiWire {}

// MARK: - Server → client

extension KunaiWire {

    /// The event tags the notch acts on. `unknown` is not a failure: kunai ships
    /// events this app has no surface for (`compact`, `rate_limit`, `failover`,
    /// subagent nesting), and those must decode and be ignored rather than break
    /// the stream.
    enum EventKind: String, Codable, Sendable {
        case hello
        case user
        case delta
        case thinking
        case assistant
        case permission
        case permissionResolved = "permission_resolved"
        case toolResult = "tool_result"
        case mode
        case result
        case state
        case error
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = EventKind(rawValue: raw) ?? .unknown
        }
    }

    /// One content block of a full assistant message.
    struct Block: Decodable, Sendable, Equatable {
        /// `"text"` | `"tool_use"` | `"thinking"`.
        var type: String
        var text: String?
        var id: String?
        var name: String?

        enum CodingKeys: String, CodingKey { case type, text, id, name }
    }

    /// A server → client frame.
    ///
    /// `seq` is the resume key and `epoch` is what makes resuming safe: it
    /// identifies the process behind a session id and changes on every respawn. A
    /// client that sees a new epoch **must** drop its last-seen sequence and
    /// rebuild, because the replacement process numbers its events from 1 again and
    /// a retained high-water mark would swallow the whole conversation as
    /// already-seen.
    struct Event: Decodable, Sendable {
        var seq: UInt64
        var kind: EventKind

        // hello
        var id: String?
        var epoch: String?
        var cwd: String?
        var model: String?
        var title: String?
        var state: String?
        var mode: String?
        var highSeq: UInt64?
        var pending: [Event]?

        // user / delta / thinking
        var text: String?

        // assistant
        var blocks: [Block]?

        // permission / permission_resolved
        var requestID: String?
        var toolName: String?
        var toolUseID: String?
        var input: [String: JSONValue]?
        var permTitle: String?
        var description: String?
        var behavior: String?

        // tool_result
        var content: String?
        var isError: Bool?

        // result
        var durationMs: Int64?
        var costUSD: Double?

        // error
        var message: String?

        enum CodingKeys: String, CodingKey {
            case seq
            case kind = "t"
            case id, epoch, cwd, model, title, state, mode
            case highSeq = "high_seq"
            case pending, text, blocks
            case requestID = "request_id"
            case toolName = "tool_name"
            case toolUseID = "tool_use_id"
            case input
            case permTitle = "perm_title"
            case description, behavior, content
            case isError = "is_error"
            case durationMs = "duration_ms"
            case costUSD = "cost_usd"
            case message
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // `seq` is absent on a malformed frame rather than zero; treating that
            // as 0 keeps the stream alive and the frame simply never advances the
            // resume mark.
            seq = (try? c.decode(UInt64.self, forKey: .seq)) ?? 0
            kind = (try? c.decode(EventKind.self, forKey: .kind)) ?? .unknown
            id = try? c.decode(String.self, forKey: .id)
            epoch = try? c.decode(String.self, forKey: .epoch)
            cwd = try? c.decode(String.self, forKey: .cwd)
            model = try? c.decode(String.self, forKey: .model)
            title = try? c.decode(String.self, forKey: .title)
            state = try? c.decode(String.self, forKey: .state)
            mode = try? c.decode(String.self, forKey: .mode)
            highSeq = try? c.decode(UInt64.self, forKey: .highSeq)
            pending = try? c.decode([Event].self, forKey: .pending)
            text = try? c.decode(String.self, forKey: .text)
            blocks = try? c.decode([Block].self, forKey: .blocks)
            requestID = try? c.decode(String.self, forKey: .requestID)
            toolName = try? c.decode(String.self, forKey: .toolName)
            toolUseID = try? c.decode(String.self, forKey: .toolUseID)
            input = try? c.decode([String: JSONValue].self, forKey: .input)
            permTitle = try? c.decode(String.self, forKey: .permTitle)
            description = try? c.decode(String.self, forKey: .description)
            behavior = try? c.decode(String.self, forKey: .behavior)
            content = try? c.decode(String.self, forKey: .content)
            isError = try? c.decode(Bool.self, forKey: .isError)
            durationMs = try? c.decode(Int64.self, forKey: .durationMs)
            costUSD = try? c.decode(Double.self, forKey: .costUSD)
            message = try? c.decode(String.self, forKey: .message)
        }

        /// Memberwise init for tests and for synthesising frames locally.
        init(seq: UInt64, kind: EventKind) {
            self.seq = seq
            self.kind = kind
        }
    }
}

// MARK: - Client → server

extension KunaiWire {

    /// A client → server frame. One shape, dispatched on `t`, mirroring kunai's
    /// own `Command`.
    ///
    /// `answers` is carried for exactly one case: the `AskUserQuestion` tool, where
    /// kunai merges question → chosen answer into the tool's `updatedInput` on
    /// allow. Multi-select is comma-joined into one value, which is why the payload
    /// is `[String: String]` and not `[String: [String]]`.
    struct Command: Encodable, Sendable {
        var t: String
        var text: String?
        var requestID: String?
        var behavior: String?
        var always: Bool?
        var answers: [String: String]?
        var model: String?
        var mode: String?

        enum CodingKeys: String, CodingKey {
            case t, text
            case requestID = "request_id"
            case behavior, always, answers, model, mode
        }

        static func prompt(_ text: String) -> Command {
            Command(t: "prompt", text: text)
        }

        /// Answer a permission ask. `always` persists it as a session rule, which is
        /// what the approval card's **Always** means and why the card has to name
        /// precisely what that grant covers.
        static func permission(
            requestID: String,
            allow: Bool,
            always: Bool = false,
            answers: [String: String]? = nil
        ) -> Command {
            Command(
                t: "permission",
                requestID: requestID,
                behavior: allow ? "allow" : "deny",
                always: always ? true : nil,
                answers: answers)
        }

        static func interrupt() -> Command { Command(t: "interrupt") }

        static func setMode(_ mode: PermissionMode) -> Command {
            Command(t: "set_mode", mode: mode.rawValue)
        }
    }
}

// MARK: - Vocabulary

extension KunaiWire {

    /// What a session is doing. kunai's own turn/session states.
    enum SessionState: String, Sendable {
        case starting
        case idle
        case running
        case awaitingPermission = "awaiting_permission"

        init(wire: String?) {
            self = SessionState(rawValue: wire ?? "") ?? .idle
        }
    }

    /// Claude Code's permission modes, as the notch offers them.
    ///
    /// `bypassPermissions` is deliberately **not** a case. It exists in the CLI, but
    /// a surface whose whole consent story is a three-answer approval card should
    /// not also offer a one-tap "never ask me anything again" — and it cannot be
    /// undone from the same panel that set it. Someone who wants it can set it where
    /// the session lives.
    enum PermissionMode: String, Sendable, CaseIterable, Identifiable {
        /// Ask before every tool that wants consent. The shipped default.
        case ask = "default"
        /// Apply edits without asking. The safety net becomes the turn diff and its
        /// undo, not the approval card.
        case auto = "acceptEdits"
        /// Plan only: no edits, no commands.
        case plan

        var id: String { rawValue }

        var label: String {
            switch self {
            case .ask: return "Ask"
            case .auto: return "Auto"
            case .plan: return "Plan"
            }
        }

        /// What choosing this mode actually means, in the user's terms. Shown beside
        /// the control, because "Auto" alone does not tell anyone that approval is
        /// being traded for undo.
        var explanation: String {
            switch self {
            case .ask: return "Asks before each change"
            case .auto: return "Applies edits, undo per turn"
            case .plan: return "Plans only, changes nothing"
            }
        }

        init(wire: String?) {
            self = PermissionMode(rawValue: wire ?? "") ?? .ask
        }
    }
}

// MARK: - Session list

extension KunaiWire {

    /// One row of `GET /api/sessions`.
    ///
    /// `turnStartedAt` is milliseconds and zero whenever nothing is running, which
    /// is what lets a row say *how long* it has been working rather than only that
    /// it is. kunai zeroes it the moment a turn ends, so it can never outlive the
    /// work it measures.
    struct SessionMeta: Decodable, Sendable, Identifiable, Equatable {
        var id: String
        var cwd: String
        var title: String
        var state: String
        var model: String?
        var turnStartedAt: Int64?
        var turnEndedAt: Int64?

        enum CodingKeys: String, CodingKey {
            case id, cwd, title, state, model
            case turnStartedAt = "turn_started_at"
            case turnEndedAt = "turn_ended_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            cwd = (try? c.decode(String.self, forKey: .cwd)) ?? ""
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            state = (try? c.decode(String.self, forKey: .state)) ?? "idle"
            model = try? c.decode(String.self, forKey: .model)
            turnStartedAt = try? c.decode(Int64.self, forKey: .turnStartedAt)
            turnEndedAt = try? c.decode(Int64.self, forKey: .turnEndedAt)
        }

        init(id: String, cwd: String, title: String, state: String,
             model: String? = nil, turnStartedAt: Int64? = nil, turnEndedAt: Int64? = nil) {
            self.id = id
            self.cwd = cwd
            self.title = title
            self.state = state
            self.model = model
            self.turnStartedAt = turnStartedAt
            self.turnEndedAt = turnEndedAt
        }
    }
}
