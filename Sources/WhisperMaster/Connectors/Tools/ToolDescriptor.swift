import Foundation

/// Whether a tool observes or changes something. The whole consent model hangs off
/// this one bit.
enum ToolAccess: String, Codable, Sendable {
    case read
    case write
    /// Changes nothing outside this Mac: the user's own on-device notes and
    /// reminders. Deliberately **not** `.write` — a write is a call to somebody
    /// else's service, which is what the approval card exists to gate, and routing a
    /// note through a consent card the user answers by holding a key would be a
    /// prompt with one possible answer. The chord *is* the consent here.
    case local
}

/// One parameter of a tool, in just enough schema to validate a model's call.
///
/// Hand-rolled rather than a general JSON Schema implementation: the tool surface is
/// deliberately small and flat (a 4-bit 3B model is the constraint), so nested objects,
/// `oneOf` and `$ref` would be capability we don't want the model to have anyway.
/// Keeping the schema language small keeps invalid calls impossible to express.
struct ToolParameter: Equatable, Sendable {
    enum ValueType: String, Sendable {
        case string
        case integer
        case boolean
    }

    let name: String
    let type: ValueType
    let isRequired: Bool
    let description: String
    /// When non-empty, the value must be one of these. Used for the `instance`
    /// parameter, which is filled with the user's actual connector labels — so the
    /// model picks from real names rather than inventing one.
    let allowedValues: [String]

    init(_ name: String,
         type: ValueType = .string,
         isRequired: Bool = false,
         description: String,
         allowedValues: [String] = []) {
        self.name = name
        self.type = type
        self.isRequired = isRequired
        self.description = description
        self.allowedValues = allowedValues
    }
}

/// A tool the agent can call. Pure data, declared once and expanded per-user by
/// `ToolRegistry` — openworker's `tool_defs` shape.
///
/// Note there is **one tool per capability, with an `instance` parameter** — not one
/// tool per connector instance. Two named calendars don't double the tool count; they
/// become two allowed values for one argument. That keeps the surface small for a 3B
/// model no matter how many connections the user has.
struct ToolDescriptor: Equatable, Sendable, Identifiable {
    let name: String
    /// One line, shown to the model. Written as an instruction, not marketing.
    let summary: String
    let access: ToolAccess
    /// The capability an instance must provide to serve this tool.
    let capability: ConnectorCapability?
    /// **Required for `.write`**: which parameter names the thing being acted upon.
    /// A standing grant binds to `(tool, instanceID, this argument's value)`, so a write
    /// tool without one could only ever be granted blanket permission — which is why
    /// `ToolRegistry` refuses to publish one.
    let targetArg: String?
    let parameters: [ToolParameter]

    var id: String { name }

    /// The `instance` parameter is added by the registry, which knows the user's labels.
    static let instanceArgument = "connector"
}

/// The catalog of tools, before per-user expansion.
enum ToolCatalog {
    static let all: [ToolDescriptor] = [
        ToolDescriptor(
            name: "list_calendar_events",
            summary: "List today's calendar events. Omit connector to merge every calendar.",
            access: .read,
            capability: .events,
            targetArg: nil,
            parameters: []),

        ToolDescriptor(
            name: "list_tasks",
            summary: "List open tasks and issues assigned to the user.",
            access: .read,
            capability: .tasks,
            targetArg: nil,
            parameters: []),

        ToolDescriptor(
            name: "list_messages",
            summary: "List recent chat channels and conversations.",
            access: .read,
            capability: .messages,
            targetArg: nil,
            parameters: []),

        ToolDescriptor(
            name: "list_connectors",
            summary: "List the user's connected accounts and what each one is named.",
            access: .read,
            capability: nil,
            targetArg: nil,
            parameters: []),

        ToolDescriptor(
            name: "send_message",
            summary: "Post a message to a chat channel.",
            access: .write,
            capability: .messages,
            targetArg: "channel",
            parameters: [
                ToolParameter("channel", isRequired: true,
                              description: "Channel name or id to post to."),
                ToolParameter("text", isRequired: true,
                              description: "The message body."),
            ]),

        ToolDescriptor(
            name: "create_calendar_event",
            summary: "Create a calendar event.",
            access: .write,
            capability: .events,
            targetArg: "calendar",
            parameters: [
                ToolParameter("calendar", isRequired: true,
                              description: "Calendar id to create the event on."),
                ToolParameter("title", isRequired: true,
                              description: "Event title."),
                ToolParameter("start", isRequired: true,
                              description: "Start time, ISO-8601."),
                ToolParameter("end", isRequired: true,
                              description: "End time, ISO-8601."),
            ]),
    ]

    static func descriptor(named name: String) -> ToolDescriptor? {
        all.first { $0.name == name }
    }
}
