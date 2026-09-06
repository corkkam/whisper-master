import Foundation

/// What the assistant is doing right now, named by the thing it's doing it *to*.
///
/// The chord suppresses the paste, so between letting go and the answer landing the
/// band is the only thing telling the user their words went anywhere at all — and it
/// said "Working on it" for the whole run, up to `AgentLoop.budget` (30s) across as
/// many as `maxIterations` tool calls. That's honest but uninformative: it can't
/// distinguish reading a calendar from posting to Slack, and on the common failure —
/// a connector that's slow or unreachable — it gives the user nothing to act on.
///
/// So each step captions itself with the connector it touches, and a run that spans
/// several connectors says each in turn. **The tool's own name is never shown**: a
/// notch reading `list_calendar_events` is the same class of leak as the approval
/// card's raw arguments were, so an unrecognised tool falls back to the generic line
/// rather than printing its identifier.
///
/// Pure and `Sendable`, so `AgentStepTests` pins the captions without a model.
enum AgentActivity: Equatable, Sendable {
    /// The model is reasoning — before the first tool call, and between them.
    case thinking
    /// A tool is executing. `target` is the connector the call named (or the channel,
    /// for a write that has one); nil when the call was unqualified, which for a read
    /// means *every* connector of that kind.
    case running(tool: String, target: String?)

    /// The step in the user's words, for the band's leading edge.
    ///
    /// Deliberately short. This is the notch row's state word, which sits in the wing
    /// beside the camera housing — `NotchSurfaceLayout.wideWing(forStateLabel:)` grows
    /// the band to fit a long connector name, but a caption that reads like a sentence
    /// would push the band across half the menu bar.
    var caption: String {
        switch self {
        case .thinking:
            return Self.generic
        case .running(let tool, let target):
            switch tool {
            case "list_calendar_events": return "Checking \(target ?? "your calendars")"
            case "list_messages": return "Checking \(target ?? "your messages")"
            case "list_tasks": return "Checking \(target ?? "your tasks")"
            case "list_connectors": return "Checking connections"
            case "create_calendar_event": return "Adding to \(target ?? "your calendar")"
            case "send_message": return "Posting to \(target ?? "chat")"
            case "create_note": return "Saving a note"
            case "create_reminder": return "Setting a reminder"
            case "list_reminders": return "Checking reminders"
            default: return Self.generic
            }
        }
    }

    /// The line for a run that has nothing more specific to say. Also what a tool
    /// this file doesn't know about falls back to.
    static let generic = "Working on it"

    /// The step for a call about to run.
    ///
    /// The target is read from the descriptor's own `targetArg` where it declares one
    /// (`send_message` → the channel), and from the connector argument otherwise —
    /// which is the same field for `create_calendar_event`, whose target *is* the
    /// connection, and the right field for a read, which declares no target but can
    /// still be scoped to one connection.
    static func running(_ call: ToolCall) -> AgentActivity {
        let descriptor = ToolCatalog.descriptor(named: call.tool)
            ?? LocalToolCatalog.descriptor(named: call.tool)
        let key = descriptor?.targetArg ?? ToolDescriptor.instanceArgument
        let value = call.arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .running(tool: call.tool, target: (value?.isEmpty ?? true) ? nil : value)
    }
}
