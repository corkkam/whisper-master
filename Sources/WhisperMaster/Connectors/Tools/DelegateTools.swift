import Foundation

/// The tools that reach a coding agent on this Mac: hand a task to the Desk
/// (`AgentDesk`), and list the sessions the agent surface already holds. kunai and
/// Shed run the agents; this app is a client only.
///
/// `delegate_task` sends text off the Mac: Claude Code passes the task to the user's
/// model provider. So it is a `.write` on the "This Mac" route with a card on every
/// call (never a grant), and it is offered only after the one-time consent
/// (`DeskConsentSheet`) and never for a capture that must stay on this Mac.
enum DelegateToolCatalog {
    static let delegateTask = ToolDescriptor(
        name: "delegate_task",
        summary: "Hand a task that no other tool can do to Claude Code on this Mac, "
            + "such as work on code or files. Its answer comes later.",
        access: .write,
        capability: nil,
        targetArg: "task",
        parameters: [
            ToolParameter("task", isRequired: true, description: "The task, in the user's own words."),
        ])

    static let listCodingTasks = ToolDescriptor(
        name: "list_coding_tasks",
        summary: "List the coding agent sessions on this Mac and what each one is doing.",
        access: .read,
        capability: nil,
        targetArg: nil,
        parameters: [])

    static let names: Set<String> = [delegateTask.name, listCodingTasks.name]

    /// Rows `list_coding_tasks` returns at most.
    static let maxRows = 10

    /// The tools one run offers.
    ///
    /// - `list_coding_tasks` needs a kunai or a Shed that answered.
    /// - `delegate_task` needs a capture that may leave this Mac
    ///   (`AgentEndpoint.staysLocal`) and one route: kunai with the Desk folder and its
    ///   consent (this client has no route that starts a Shed session), or a Crew
    ///   project with the Crew consent.
    static func offered(kunai: Bool, shed: Bool, deskFolder: String?,
                        consented: Bool, staysLocal: Bool,
                        crewProject: String? = nil, crewConsented: Bool = false) -> [ToolDescriptor] {
        let desk = kunai && deskFolder != nil && consented
        let crew = crewProject != nil && crewConsented
        let delegate = (desk || crew) && !staysLocal
        return (delegate ? [delegateTask] : []) + (kunai || shed ? [listCodingTasks] : [])
    }
}

/// What a trace keeps of a hand-off: where the task went and its length, never its
/// text. Traces persist.
struct HandOffTrace: Codable, Hashable, Sendable {
    var destination: String
    var characters: Int
}

/// Runs a `DelegateToolCatalog` call.
@MainActor
struct DelegateToolRunner {
    /// What the tools reach. The default offers nothing and reaches nothing, so a
    /// caller with no agent surface (a test, the bench) needs no stub.
    struct Environment {
        /// The tools this run offers (`DelegateToolCatalog.offered`).
        var tools: [ToolDescriptor] = []
        /// The folder the task runs in: the Desk's (`AgentDesk.folder`) or the Crew project.
        var deskFolder: String?
        /// What the card and the result call the receiver. Nil means the Desk.
        var destination: String?
        /// Send the task to the Desk. Nil when it went, else why not.
        var handOff: @MainActor (_ task: String, _ folder: String) async -> String? = { _, _ in
            "No coding agent is running on this Mac."
        }
        /// The sessions the agent surface holds (`AgentSurfaceController.heldSessions`).
        var sessions: @MainActor () -> [AgentSession] = { [] }

        /// The environment for one chord capture.
        /// kunai's Desk wins when both routes are open; the Crew takes the task otherwise.
        @MainActor static func live(agents: AgentSurfaceController, folderSetting: String,
                         consented: Bool, staysLocal: Bool,
                         crewConsented: Bool = false) -> Environment {
            let folder = AgentDesk.folder(folderSetting)
            let desk = agents.isAvailable && folder != nil && consented
            let crewProject = crewConsented ? agents.crew.project : nil
            let toCrew = !desk && crewProject != nil
            return Environment(
                tools: DelegateToolCatalog.offered(
                    kunai: agents.isAvailable, shed: agents.shed.isAvailable,
                    deskFolder: folder, consented: consented, staysLocal: staysLocal,
                    crewProject: crewProject, crewConsented: crewConsented),
                deskFolder: toCrew ? crewProject : folder,
                destination: toCrew ? crewProject.map(CrewRuns.destination(project:)) : nil,
                handOff: { [weak agents] task, folder in
                    guard let agents else { return "No coding agent is running on this Mac." }
                    return toCrew
                        ? agents.crewRuns.start(task, project: folder)
                        : await agents.handToDesk(task, folder: folder)
                },
                sessions: { [weak agents] in agents?.heldSessions ?? [] })
        }
    }

    let environment: Environment
    let requestApproval: (PendingApproval) async -> ApprovalOutcome
    /// Shared with the run's other routers.
    var taint = Taint()
    var now: () -> Date = Date.init

    static let stoppedBeforeHandOff = "Stopped before it ran, so nothing was handed off."

    func run(_ call: ToolCall) async -> (result: ToolResult, handOff: HandOffTrace?) {
        switch call.tool {
        case DelegateToolCatalog.delegateTask.name: return await delegate(call)
        case DelegateToolCatalog.listCodingTasks.name: return (list(), nil)
        default: return (.failure("No such tool: \(call.tool)."), nil)
        }
    }

    // MARK: - delegate_task

    private func delegate(_ call: ToolCall) async -> (ToolResult, HandOffTrace?) {
        guard let folder = environment.deskFolder else {
            return (.failure("No project folder is set for Claude Code, so nothing was handed off."), nil)
        }
        // The card shows this exact text, whole, in its scroll area, and the Desk gets it.
        let task = (call.arguments["task"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !AgentDraft.hasHiddenCharacters(task) else {
            return (.failure("The task has characters the card can't show, so it wasn't handed off."), nil)
        }
        let destination = environment.destination ?? AgentDesk.destination(folder: folder)
        // No grants are passed: a hand-off asks every time, so a grant can never answer.
        if case .refused(let reason) = WriteAuthorizer.authorize(
            tool: DelegateToolCatalog.delegateTask, instanceID: DeviceToolCatalog.thisMacID,
            target: task, grants: [], tainted: taint.isSet) {
            return (.failure(reason), nil)
        }
        guard !Task.isCancelled else { return (.failure(Self.stoppedBeforeHandOff), nil) }
        let askedAt = now()
        let outcome = await requestApproval(PendingApproval(
            tool: DelegateToolCatalog.delegateTask.name,
            instanceID: DeviceToolCatalog.thisMacID,
            instanceLabel: destination,
            target: task,
            arguments: ["task": task],
            grantOffered: !taint.isSet,
            grantable: false))
        let waited = Int(now().timeIntervalSince(askedAt) * 1000)
        switch outcome {
        case .denied:
            return (ToolResult(ok: false, text: "The user declined that.", instanceLabels: [],
                               authorization: .denied, approvalMilliseconds: waited), nil)
        case .timedOut:
            return (ToolResult(ok: false,
                               text: "Nobody answered the approval card in time, so nothing was handed off.",
                               instanceLabels: [], authorization: .timedOut,
                               approvalMilliseconds: waited), nil)
        case .allowedOnce, .allowedAlways:
            // The card hides Always, so an Always answer runs once and stores nothing.
            break
        }
        guard !Task.isCancelled else {
            return (ToolResult(ok: false, text: Self.stoppedBeforeHandOff, instanceLabels: [],
                               approvalMilliseconds: waited), nil)
        }
        if let reason = await environment.handOff(task, folder) {
            return (ToolResult(ok: false, text: reason, instanceLabels: [],
                               authorization: .allowedOnce, approvalMilliseconds: waited), nil)
        }
        var result = ToolResult(ok: true,
                                text: "Sent to \(destination). Its answer shows in the notch when it is done.",
                                instanceLabels: [], authorization: .allowedOnce,
                                approvalMilliseconds: waited)
        // The Desk works for minutes; the loop's 30 s budget must not wait for it.
        result.endsTurn = true
        return (result, HandOffTrace(destination: destination, characters: task.count))
    }

    // MARK: - list_coding_tasks

    /// The sessions the client already holds, one line each. Session titles and status
    /// come from another program, so the run is tainted like a connector read.
    private func list() -> ToolResult {
        let sessions = environment.sessions()
        let rows = sessions.prefix(DelegateToolCatalog.maxRows).map { session -> String in
            let machine = session.isRemote ? session.machineLabel : "this Mac"
            let activity = session.subtitle.isEmpty ? "" : " — \(ToolRouter.oneLine(session.subtitle))"
            return "\(ToolRouter.oneLine(session.displayName)) — \(machine) — "
                + "\(session.statusLabel(now: now()))\(activity)"
        }
        taint.isSet = true
        taint.outsideSelection = true
        let more = sessions.count - rows.count
        let text = rows.isEmpty
            ? "No coding agent sessions are running."
            : rows.joined(separator: "\n") + (more > 0 ? "\n\(more) more not shown." : "")
        return ToolResult(ok: true, text: text, instanceLabels: [])
    }
}
