import Foundation
import Observation

/// Shed's coding agents (Claude Code and Codex sessions Shed runs on this Mac), as
/// the notch sees them. Held by `AgentSurfaceController` beside kunai.
///
/// Shed has no per-session socket, so this is small: a list kept current by Shed's
/// server-sent events (with a slow poll as the fallback that notices it coming back),
/// the one question that is on screen, and the phone-access state for Settings.
/// Dormant until `start()`, like the controller, so tests and the snapshot renderer
/// open no connection.
@MainActor
@Observable
final class ShedAgents {

    /// Live sessions only (working, asking, idle), ranked for the glance.
    private(set) var sessions: [AgentSession] = []
    private(set) var isAvailable = false
    /// The question on a session's terminal, as a choice card. Nil when none.
    private(set) var ask: AgentAsk?
    private(set) var askSessionID: String?
    private(set) var phoneAccess: ShedWire.PhoneAccess?
    /// False once Shed answered 404 on phone access: an older Shed with no such route.
    private(set) var phoneAccessSupported = true
    private(set) var phoneMessage: String?
    private(set) var isChangingPhoneAccess = false
    /// Nil until Shed has an accounts route. Account controls stay hidden meanwhile.
    private(set) var accounts: [ShedWire.Account]?

    private(set) var isEnabled = true
    private(set) var urlOverride = ""

    static let pollInterval: Duration = .seconds(3)
    static let offlineInterval: Duration = .seconds(6)

    private var client: any ShedAPI
    private let makeClient: (String) -> any ShedAPI
    private var menu: ShedWire.Menu?
    /// Questions the user skipped, so the next poll does not put the same one back.
    private var skipped: Set<String> = []
    private var firstSeenWorking: [String: Int64] = [:]
    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    init(makeClient: @escaping (String) -> any ShedAPI = { ShedClient(candidates: ShedEndpoint.candidates(override: $0)) }) {
        self.makeClient = makeClient
        self.client = makeClient("")
    }

    var running: [AgentSession] { sessions.filter { $0.state == .running } }
    var needsYou: Bool { sessions.contains { $0.isWaiting } }
    var isActive: Bool { isEnabled && isAvailable && !sessions.isEmpty }
    var hasRunning: Bool { isEnabled && isAvailable && !running.isEmpty }

    /// The label of the session that is asking, for the card's second line.
    var askingLabel: String {
        sessions.first { $0.id == askSessionID }?.displayName ?? ""
    }

    /// The glyphs for the left wing: one per distinct harness among running agents.
    var runningHarnesses: [AgentHarness] {
        var seen: [AgentHarness] = []
        for session in running where !seen.contains(session.harness) { seen.append(session.harness) }
        return seen
    }

    // MARK: Lifecycle

    /// Applies the Settings values. Never starts anything before `start()` has run.
    func configure(enabled: Bool, urlOverride: String) {
        let urlChanged = urlOverride != self.urlOverride
        guard enabled != isEnabled || urlChanged else { return }
        isEnabled = enabled
        self.urlOverride = urlOverride
        if urlChanged { client = makeClient(urlOverride) }
        halt()
        if started { spawn() }
    }

    func start() {
        started = true
        spawn()
    }

    func stop() {
        started = false
        halt()
    }

    private var started = false

    private func spawn() {
        guard isEnabled, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let delay = (self?.isAvailable ?? false) ? Self.pollInterval : Self.offlineInterval
                try? await Task.sleep(for: delay)
            }
        }
        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let stream = self?.client.events() else { return }
                for await event in stream {
                    guard let self else { return }
                    await self.receive(event)
                }
                try? await Task.sleep(for: Self.offlineInterval)
            }
        }
    }

    private func halt() {
        pollTask?.cancel()
        eventTask?.cancel()
        pollTask = nil
        eventTask = nil
        clear()
    }

    private func clear() {
        sessions = []
        isAvailable = false
        ask = nil
        askSessionID = nil
        menu = nil
    }

    // MARK: Reading

    func receive(_ event: ShedEvent) async {
        guard event.name == "sessions" || event.name == "status" else { return }
        // Show the new state at once; the list then confirms it and adds new rows.
        for change in event.statusChanges ?? [] {
            guard let state = AgentSession.state(fromShed: change.liveState),
                  let index = sessions.firstIndex(where: { $0.id == change.id })
            else { continue }
            sessions[index].state = state
        }
        await refresh()
    }

    func refresh() async {
        guard isEnabled else { return }
        let list = await client.agentSessions()
        let reachable = await client.isReachable
        isAvailable = reachable
        guard reachable else { clear(); return }
        apply(list)
        await reconcileAsk()
        if phoneAccess == nil, phoneAccessSupported { await refreshPhoneAccess() }
        if accounts == nil { accounts = await client.accounts() }
    }

    private func apply(_ incoming: [AgentSession]) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var live = Set<String>()
        sessions = incoming.map { session in
            var session = session
            live.insert(session.id)
            if session.state == .running {
                session.turnStartedAt = firstSeenWorking[session.id] ?? nowMs
                firstSeenWorking[session.id] = session.turnStartedAt
            } else {
                firstSeenWorking[session.id] = nil
            }
            return session
        }.rankedForGlance()
    }

    // MARK: Asks

    /// Keep the card in step with Shed: read the menu of the session that is asking,
    /// and drop the card when nothing is.
    private func reconcileAsk() async {
        guard let asking = sessions.first(where: \.isWaiting) else {
            ask = nil; askSessionID = nil; menu = nil; skipped = []
            return
        }
        await loadMenu(for: asking.id)
    }

    private func loadMenu(for sessionID: String) async {
        guard let terminal = await client.terminal(sessionID: sessionID),
              let built = ShedAsk.make(
                sessionID: sessionID,
                context: sessions.first { $0.id == sessionID }?.displayName ?? "",
                terminal: terminal),
              let options = terminal.menu?.options
        else {
            if askSessionID == sessionID { ask = nil; menu = nil }
            return
        }
        guard !skipped.contains(Self.signature(sessionID, options)) else { return }
        ask = built
        askSessionID = sessionID
        menu = terminal.menu
    }

    private static func signature(_ id: String, _ options: [String]) -> String {
        id + "\u{1F}" + options.joined(separator: "\u{1F}")
    }

    /// Send the chosen option back. An empty selection is a skip: nothing is sent,
    /// because dismissing the card must never answer a real prompt.
    func answer(_ choice: AgentChoice, selected: [String]) async {
        guard choice.requestID == askSessionID, let menu else { return }
        guard let label = selected.first, let index = menu.options.firstIndex(of: label) else {
            skipped.insert(Self.signature(choice.requestID, menu.options))
            ask = nil
            return
        }
        let sessionID = choice.requestID
        switch await client.choose(sessionID: sessionID, index: index, label: label) {
        case .chosen:
            ask = nil; askSessionID = nil; self.menu = nil
            await refresh()
        case .changed:
            // The question moved on while the card was up. Read it again and show it.
            ask = nil
            await loadMenu(for: sessionID)
        case .failed:
            break  // the card stays, so the user can try again
        }
    }

    // MARK: Actions

    func interrupt(sessionID: String) {
        Task { _ = await client.interrupt(sessionID: sessionID) }
    }

    func isShedSession(_ id: String) -> Bool { sessions.contains { $0.id == id } }

    /// The Shed the notch reads. The Coding tab shows the same one.
    var activeEndpoint: ShedEndpoint? {
        get async { await client.activeEndpoint }
    }

    /// "Open full session" has one door, `ShedLink`, which opens the Coding tab.
    func openFullSession(_ id: String) {
        Task { ShedLink.openSession(id: id, endpoint: await client.activeEndpoint) }
    }

    // MARK: Phone access

    func refreshPhoneAccess() async {
        if let access = await client.phoneAccess() {
            phoneAccess = access
            phoneAccessSupported = true
        } else if isAvailable {
            phoneAccessSupported = false
        }
    }

    func useTailscaleForPhone() async {
        isChangingPhoneAccess = true
        phoneMessage = nil
        switch await client.useTailscale() {
        case .updated(let access):
            phoneAccess = access
            phoneAccessSupported = true
        case .failed(let message):
            phoneMessage = message
        }
        isChangingPhoneAccess = false
    }

    static let tailscaleNote =
        "To use agents from your phone, install Tailscale on the phone and sign in to the same tailnet."

    // MARK: Snapshots and tests

    func seedForSnapshot(sessions: [AgentSession], ask: AgentAsk? = nil) {
        self.sessions = sessions.rankedForGlance()
        isAvailable = true
        self.ask = ask
        askSessionID = ask?.requestID
    }
}
