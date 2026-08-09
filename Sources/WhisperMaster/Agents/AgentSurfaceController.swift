import Foundation
import Observation

/// The agent surface's one piece of state, and the only thing that talks to kunai.
///
/// Held by `AppState` the same way `ApprovalCoordinator` is, so the notch views read
/// it directly and nothing else in the app needs to know kunai exists.
///
/// Three rules shape it:
///
/// - **It starts dormant.** `start()` is explicit, so `swift test` and the headless
///   snapshot renderer can build an `AppState` without opening a socket or polling a
///   port. Same posture as `UsageStore(load: false)`.
/// - **It attaches to one session, and only when there is a reason to.** The poll
///   already knows which sessions are waiting, because kunai reports
///   `awaiting_permission` in the session list. The socket is opened for the session
///   that is *asking*, or the one the user opened to read. Attaching to everything
///   would mean N sockets to render one band.
/// - **Absence is normal.** kunai may never be installed. Nothing here throws or
///   surfaces an error state; the surface is simply dark.
@MainActor
@Observable
final class AgentSurfaceController {

    // MARK: Observable state

    /// Every live session, ranked for the glance.
    private(set) var sessions: [AgentSession] = []

    /// The question the notch is currently putting to the user, if any.
    private(set) var ask: AgentAsk?

    /// The session whose transcript is open, if the user drilled in.
    private(set) var openSessionID: String?

    /// The readable tail of the open (or asking) session.
    private(set) var log = AgentTurnLog()

    /// What the open session's latest turn changed.
    private(set) var changeSet = AgentChangeSet()

    /// True once a kunai has answered. Until then the surface stays dark, which is
    /// the correct state on the overwhelming majority of Macs.
    private(set) var isAvailable = false

    /// The session the user is speaking to when they hold the key with the panel
    /// open. Nil means dictation behaves exactly as it always has.
    var voiceTarget: AgentSession? {
        guard let id = openSessionID ?? ask.flatMap({ _ in attachedSessionID }) else { return nil }
        return sessions.first { $0.id == id }
    }

    /// The session that is asking, for the banner's second line.
    var askingSession: AgentSession? {
        guard let attachedSessionID else { return nil }
        return sessions.first { $0.id == attachedSessionID }
    }

    // MARK: Collaborators

    private let rest: KunaiRESTClient
    private var stream: KunaiEventStream?
    private var attachedSessionID: String?
    private var pumpTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    /// How often the session list is refreshed. Deliberately far slower than the
    /// AppDelegate's 0.5s UI tick: this is a network call, the answer changes on
    /// human timescales, and an idle Mac should not be making two requests a second
    /// for the life of the process.
    var pollInterval: Duration = .seconds(3)

    /// The address the socket is opened against: whichever candidate answered the
    /// last session poll. Held here rather than resolved again, so a machine running
    /// two kunai channels cannot read its sessions from one and attach to the other.
    private var endpoint: KunaiEndpoint?

    init(candidates: [KunaiEndpoint] = KunaiEndpoint.candidates) {
        self.rest = KunaiRESTClient(candidates: candidates)
    }

    // MARK: Lifecycle

    /// Begin polling. Idempotent.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        detach()
        sessions = []
        isAvailable = false
    }

    // MARK: Polling

    /// One pass: refresh the session list, then make sure we are attached to
    /// whatever deserves a socket.
    func refresh() async {
        let metas = await rest.sessions()
        let reachable = await rest.isReachable
        endpoint = await rest.active
        isAvailable = reachable

        guard reachable else {
            sessions = []
            detach()
            return
        }

        // Preserve the mode we already learned from each session's socket: the list
        // endpoint does not carry it, and dropping it would flip the mode control
        // back to Ask on every poll.
        let knownModes = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.mode) })
        sessions = metas
            .map { AgentSession(meta: $0, mode: knownModes[$0.id] ?? .ask) }
            .rankedForGlance()

        reconcileAttachment()
    }

    /// Attach to the session that most deserves the socket: the one the user opened,
    /// else the one that is waiting on them.
    private func reconcileAttachment() {
        let wanted = openSessionID ?? sessions.first(where: \.isWaiting)?.id
        guard wanted != attachedSessionID else { return }
        detach()
        guard let wanted else { return }
        attach(to: wanted)
    }

    // MARK: Attachment

    private func attach(to sessionID: String) {
        guard let endpoint else { return }
        let stream = KunaiEventStream(endpoint: endpoint, sessionID: sessionID)
        self.stream = stream
        attachedSessionID = sessionID
        log.reset()
        changeSet = AgentChangeSet()

        pumpTask = Task { [weak self] in
            let frames = await stream.connect()
            for await frame in frames {
                guard let self else { return }
                await self.handle(frame)
            }
        }
    }

    private func detach() {
        pumpTask?.cancel()
        pumpTask = nil
        let closing = stream
        stream = nil
        attachedSessionID = nil
        ask = nil
        Task { await closing?.disconnect() }
    }

    private func handle(_ frame: KunaiEventStream.Frame) {
        switch frame {
        case .reset:
            // The session respawned: everything we hold describes a dead process.
            log.reset()
            ask = nil
            changeSet = AgentChangeSet()

        case .disconnected:
            ask = nil

        case .event(let event):
            apply(event)
        }
    }

    private func apply(_ event: KunaiWire.Event) {
        log.apply(event)
        changeSet.editedPaths = AgentChangeSet.editedPaths(in: log)

        switch event.kind {
        case .hello:
            if let mode = event.mode { updateMode(KunaiWire.PermissionMode(wire: mode)) }
            // `pending` carries the asks that were already outstanding when we
            // attached. Without reading it, a question raised before the panel opened
            // would never be shown and the turn would sit behind it.
            for pendingEvent in event.pending ?? [] { raiseAsk(from: pendingEvent) }

        case .mode:
            updateMode(KunaiWire.PermissionMode(wire: event.mode))

        case .permission:
            raiseAsk(from: event)

        case .permissionResolved:
            if ask?.requestID == event.requestID { ask = nil }

        default:
            break
        }
    }

    private func raiseAsk(from event: KunaiWire.Event) {
        guard event.kind == .permission || event.requestID != nil else { return }
        let title = askingSession?.repo ?? ""
        guard let built = AgentAsk.make(from: event, sessionTitle: title) else { return }
        // First question wins. A second card stacked on the first would hide which
        // one the buttons answer.
        if ask == nil { ask = built }
    }

    private func updateMode(_ mode: KunaiWire.PermissionMode) {
        guard let attachedSessionID,
              let index = sessions.firstIndex(where: { $0.id == attachedSessionID })
        else { return }
        sessions[index].mode = mode
    }

    // MARK: Actions

    /// Answer an approval card.
    func resolve(_ ask: AgentAsk, allow: Bool, always: Bool = false) {
        send(.permission(requestID: ask.requestID, allow: allow, always: always))
        self.ask = nil
    }

    /// Answer a choice card. Denying is still an allow-with-no-answer in kunai's
    /// model only when the user picked something; a dismissal is a deny.
    func answer(_ choice: AgentChoice, question: AgentChoice.Question, selected: [String]) {
        guard !selected.isEmpty else {
            send(.permission(requestID: choice.requestID, allow: false))
            ask = nil
            return
        }
        send(.permission(
            requestID: choice.requestID, allow: true,
            answers: AgentChoice.answers(for: question, selected: selected)))
        ask = nil
    }

    /// Send a dictated prompt to the session the panel is pointed at.
    func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(.prompt(trimmed))
    }

    func setMode(_ mode: KunaiWire.PermissionMode) {
        send(.setMode(mode))
        updateMode(mode)
    }

    /// Open a session's transcript, which is also what makes it the voice target.
    func open(sessionID: String?) {
        openSessionID = sessionID
        reconcileAttachment()
        guard sessionID != nil, let attachedSessionID else { return }
        Task { [weak self] in
            let preview = await self?.rest.revertPreview(
                sessionID: attachedSessionID, seq: self?.log.highestSeq ?? 0)
            guard let preview else { return }
            self?.changeSet.revert = preview
        }
    }

    private func send(_ command: KunaiWire.Command) {
        guard let stream else { return }
        Task { await stream.send(command) }
    }

    // MARK: Snapshots

    /// Put the surface into a fixed state for the headless PNG renderer.
    ///
    /// Only ever called from `SnapshotMode`, which is compiled out of Release. It
    /// sets the observable state directly and starts nothing, so no socket is opened
    /// and no port is polled.
    func seedForSnapshot(ask: AgentAsk, sessions: [AgentSession]) {
        self.sessions = sessions.rankedForGlance()
        self.ask = ask
        self.isAvailable = true
        self.attachedSessionID = sessions.first(where: \.isWaiting)?.id ?? sessions.first?.id
    }
}
