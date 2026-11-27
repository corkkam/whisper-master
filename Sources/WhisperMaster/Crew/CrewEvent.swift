import Foundation

/// One line of `~/.crew/events.jsonl`. The line carries no prompt text, tool input,
/// path or file content: only who did what, and when. An event name that this app
/// does not know still decodes. The reducer ignores it.
struct CrewEvent: Codable, Equatable, Sendable {
    var v: Int
    var ts: Date
    var src: String
    var event: String
    var session: String?
    var agent: String
    var project: String
    var tool: String?
    var kind: String?
    var note: String?
    var agents: [String]

    init(
        v: Int = 1, ts: Date, src: String = "crew", event: String, session: String? = nil,
        agent: String, project: String, tool: String? = nil, kind: String? = nil,
        note: String? = nil, agents: [String] = []
    ) {
        self.v = v
        self.ts = ts
        self.src = src
        self.event = event
        self.session = session
        self.agent = agent
        self.project = project
        self.tool = tool
        self.kind = kind
        self.note = note
        self.agents = agents
    }

    private enum CodingKeys: String, CodingKey {
        case v, ts, src, event, session, agent, project, tool, kind, note, agents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        let text = try c.decode(String.self, forKey: .ts)
        guard let date = Self.parse(text) else {
            throw DecodingError.dataCorruptedError(
                forKey: .ts, in: c, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        ts = date
        src = try c.decodeIfPresent(String.self, forKey: .src) ?? ""
        event = try c.decode(String.self, forKey: .event)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        agent = try c.decode(String.self, forKey: .agent)
        project = try c.decode(String.self, forKey: .project)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        agents = try c.decodeIfPresent([String].self, forKey: .agents) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(Self.format(ts), forKey: .ts)
        try c.encode(src, forKey: .src)
        try c.encode(event, forKey: .event)
        try c.encode(session, forKey: .session)
        try c.encode(agent, forKey: .agent)
        try c.encode(project, forKey: .project)
        try c.encode(tool, forKey: .tool)
        try c.encode(kind, forKey: .kind)
        try c.encode(note, forKey: .note)
        try c.encode(agents, forKey: .agents)
    }

    /// Nil for a line that is not JSON, lacks a required key, or has `v` other than 1.
    static func decode(line: String) -> CrewEvent? {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(CrewEvent.self, from: data),
              event.v == 1
        else { return nil }
        return event
    }

    /// Writers use milliseconds. A line without them still reads.
    static func parse(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
