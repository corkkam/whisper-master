import Foundation

/// A standing permission for one write, bound to one target on one connection.
///
/// **The three-part key is the point.** openworker binds a grant to `(tool, target)`,
/// which is safe when accounts are addressed by unique email. With user-chosen labels
/// and several instances per kind it leaks: "always allow `send_message #general`"
/// granted on a Personal Slack would silently authorise the identically-named channel
/// on Work Slack. Channel names, calendar ids and repo names are all only unique
/// *within* an account, so the instance has to be part of the key.
struct Grant: Codable, Equatable, Sendable, Identifiable {
    /// The tool this permits, e.g. `send_message`.
    let tool: String
    /// The connection it permits it on.
    let instanceID: UUID
    /// The exact target value — the tool's `targetArg` argument. Compared
    /// case-insensitively, since it round-trips through speech.
    let target: String
    let grantedAt: Date

    init(tool: String, instanceID: UUID, target: String, grantedAt: Date = Date()) {
        self.tool = tool
        self.instanceID = instanceID
        self.target = target
        self.grantedAt = grantedAt
    }

    /// Stable identity for the revoke list. Not a UUID: two grants with the same
    /// three-part key *are* the same grant.
    var id: String { "\(tool)|\(instanceID.uuidString)|\(target.lowercased())" }

    func matches(tool: String, instanceID: UUID, target: String) -> Bool {
        self.tool == tool
            && self.instanceID == instanceID
            && self.target.compare(target, options: .caseInsensitive) == .orderedSame
    }
}

/// The decision a write needs before it can run.
enum WriteAuthorization: Equatable, Sendable {
    /// A standing grant covers it — run without asking.
    case granted
    /// No grant. The user must approve this specific call.
    case needsApproval
    /// Structurally impossible to authorise, so never ask. A write tool with no
    /// resolvable target can only ever be blanket permission, which isn't on offer.
    case refused(reason: String)
}

/// How an approval card ended.
///
/// `timedOut` is not a fourth button — the card offers three — it is the card nobody
/// answered. It is still **not an authorization**, so every caller must treat it the
/// way it treats `denied`; what it must not do is *word* it the same way. "The user
/// declined that" about a card the user never saw is the app inventing an answer on
/// their behalf, and it hides the only thing worth knowing: the question was put
/// somewhere nobody was looking.
enum ApprovalOutcome: Equatable, Sendable {
    case allowedOnce
    case allowedAlways
    case denied
    case timedOut
}

/// A write waiting on the user. Held by `ApprovalCoordinator` and rendered in the notch.
struct PendingApproval: Equatable, Sendable, Identifiable {
    let id: UUID
    let tool: String
    let instanceID: UUID
    /// The connection's user-chosen name — the card must say *which* Slack.
    let instanceLabel: String
    let target: String
    /// Every argument, shown in full. An approval card that hides part of the payload
    /// isn't consent to the action that actually runs.
    let arguments: [String: String]
    let requestedAt: Date

    init(id: UUID = UUID(),
         tool: String,
         instanceID: UUID,
         instanceLabel: String,
         target: String,
         arguments: [String: String],
         requestedAt: Date = Date()) {
        self.id = id
        self.tool = tool
        self.instanceID = instanceID
        self.instanceLabel = instanceLabel
        self.target = target
        self.arguments = arguments
        self.requestedAt = requestedAt
    }

    /// One line for the notch: "Post to #general on Work".
    var headline: String {
        ApprovalCopy.headline(tool: tool, target: target, instanceLabel: instanceLabel)
    }

    /// The payload the user is actually approving, in readable form and with the
    /// target left out (it's in the headline). See `ApprovalCopy.detail` for why
    /// this is a rendering of every argument rather than a selection of some.
    var detail: String {
        ApprovalCopy.detail(tool: tool, arguments: arguments)
    }
}

/// Decides whether a write may proceed. Pure, so the leak case that motivated the
/// three-part key is directly testable.
enum WriteAuthorizer {
    static func authorize(tool: ToolDescriptor,
                          instanceID: UUID,
                          target: String?,
                          grants: [Grant]) -> WriteAuthorization {
        guard tool.access == .write else { return .granted }
        guard tool.targetArg != nil else {
            return .refused(reason: "\(tool.name) declares no target, so it can't be scoped.")
        }
        guard let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refused(reason: "\(tool.name) was called without a target.")
        }
        let covered = grants.contains { $0.matches(tool: tool.name, instanceID: instanceID, target: target) }
        return covered ? .granted : .needsApproval
    }
}
