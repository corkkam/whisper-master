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

    /// The last thing the agent actually said, and when it finished saying it.
    ///
    /// This is what the band reports when a turn ends. The notch has never streamed a
    /// transcript — it reports *state* — so a finished turn gets one line, the way
    /// every other band in the app does.
    private(set) var lastReply: String?
    /// The same reply before presentation — the markdown source the expanded band
    /// renders. The banner's one-liner is a *presentation* of this, so expanding
    /// must go back to the source rather than inflating the truncated line.
    private(set) var lastReplyRaw: String?
    private(set) var lastReplyAt: Date?
    /// How long that turn took, for the band's quiet second line.
    private(set) var lastTurnDuration: TimeInterval?

    /// True once a kunai has answered. Until then the surface stays dark, which is
    /// the correct state on the overwhelming majority of Macs.
    private(set) var isAvailable = false

    /// Whether the user has opened the surface to look at it, rather than being
    /// interrupted by it. Driven by a tap of the agent key.
    private(set) var isGlanceOpen = false

    /// When a *send* opened the surface, as opposed to a deliberate tap.
    ///
    /// The two need different lifetimes. A tap is someone choosing to look, so it
    /// stays until they close it. A reveal is a receipt for words they just spoke, so
    /// it has to appear on its own and then get out of the way — otherwise the band
    /// sits over the menu bar for the rest of the day.
    private(set) var revealedAt: Date?

    /// How long a revealed session lingers once its turn has finished. Long enough to
    /// read the reply, short enough that the notch gives the menu bar back.
    static let revealHold: TimeInterval = 10

    /// The hold for a reply that arrived already expanded (the Settings default):
    /// a full reply is a paragraph, not a line, so it earns proportionate reading
    /// time before the band retracts.
    static let expandedRevealHold: TimeInterval = 30

    /// Whether the finish banner is currently the full-reply band.
    private(set) var replyExpanded = false
    /// True when the *user clicked* it open. A pinned reply never auto-expires:
    /// closing something someone deliberately opened is the notch deciding it knows
    /// better. Arriving expanded via the Settings default does not pin.
    private(set) var replyPinned = false
    /// The Settings preference, written through by `AppState`: replies arrive
    /// already expanded.
    var expandRepliesByDefault = false

    /// The click on the finish band: collapsed → expanded and pinned; expanded →
    /// back to the one-line banner, with the retract clock restarted so the band
    /// still leaves on its own.
    func toggleReplyExpansion() {
        if replyExpanded {
            replyExpanded = false
            replyPinned = false
            lastReplyAt = Date()
        } else {
            replyExpanded = true
            replyPinned = true
        }
    }

    /// Show a session's tail because something just went to it.
    ///
    /// This is what stops a spoken prompt from disappearing: the words are suppressed
    /// from the paste, so without a surface the user has no evidence they went
    /// anywhere at all.
    func reveal(sessionID: String) {
        // The previous turn's answer must not flash up as though it were this one's.
        lastReply = nil
        lastReplyRaw = nil
        lastReplyAt = nil
        lastTurnDuration = nil
        replyExpanded = false
        replyPinned = false
        isGlanceOpen = true
        revealedAt = Date()
        openSessionID = sessionID
        reconcileAttachment()
    }

    /// Whether a revealed band has outstayed its welcome: the turn is over and the
    /// hold has elapsed. A tap-opened glance never expires this way.
    func revealHasExpired(now: Date = Date()) -> Bool {
        guard let revealedAt else { return false }
        guard !replyPinned else { return false }
        guard let session = openSession, session.state == .idle else { return false }
        // The hold is reading time for the *reply*, so it counts from when the reply
        // landed — measured from the send, a three-minute turn would expire the
        // banner the moment it appeared.
        let start = lastReplyAt ?? revealedAt
        let hold = replyExpanded ? Self.expandedRevealHold : Self.revealHold
        return now.timeIntervalSince(start) > hold
    }

    /// Open or close the glance. Closing also lets go of whichever session was being
    /// read, so the next interrupt is free to attach to whatever is actually asking.
    func toggleGlance() {
        isGlanceOpen.toggle()
        // A deliberate tap is not a receipt, so it never auto-expires.
        revealedAt = nil
        guard !isGlanceOpen else {
            Task { await refresh() }
            return
        }
        openSessionID = nil
        reconcileAttachment()
    }

    func closeGlance() {
        guard isGlanceOpen else { return }
        isGlanceOpen = false
        revealedAt = nil
        replyExpanded = false
        replyPinned = false
        openSessionID = nil
        reconcileAttachment()
    }

    /// The session the user is speaking to when they hold the key with the panel
    /// open. Nil means dictation behaves exactly as it always has.
    var voiceTarget: AgentSession? {
        guard let id = openSessionID ?? ask.flatMap({ _ in attachedSessionID }) else { return nil }
        return sessions.first { $0.id == id }
    }

    /// The session the user drilled into, if any. Nil means the glance is showing the
    /// list rather than one conversation.
    var openSession: AgentSession? {
        guard let openSessionID else { return nil }
        return sessions.first { $0.id == openSessionID }
    }

    /// The open session's page in kunai's own web app, for the "Open in kunai"
    /// affordance. kunai routes a bare `/<sessionID>` path to that session, against
    /// whichever server actually answered discovery.
    var openSessionURL: URL? {
        guard let endpoint, let id = openSessionID ?? attachedSessionID else { return nil }
        return endpoint.baseURL.appendingPathComponent(id)
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

    /// Missed polls in a row. See `refresh` — one miss is routine, several is a
    /// server that is actually gone.
    private var consecutivePollFailures = 0
    /// How many consecutive missed polls count as "gone": ~9s at the 3s cadence.
    static let pollFailureGrace = 3

    /// The history/live boundary for the attached socket. kunai replays the
    /// session's ring buffer on attach — every prior turn's frames arrive before
    /// the live ones — and `hello.high_seq` is the highest sequence that existed
    /// before we attached. Every frame at or below it is **history**: context for
    /// the log, but not something happening now. Treating replayed frames as live
    /// is what made the band re-announce every old turn on the first dictation,
    /// reply and working flashing once per turn of history.
    private var liveSince: UInt64 = 0

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

        // One failed poll is not an absent server: the 2s request timeout trips
        // routinely while kunai is busy spawning a claude process, and clearing
        // the sessions on that single miss emptied the revealed band mid-turn —
        // a bare black strip across the menu bar. The surface only goes dark
        // after the server has missed several polls in a row.
        guard reachable else {
            consecutivePollFailures += 1
            if consecutivePollFailures >= Self.pollFailureGrace {
                isAvailable = false
                sessions = []
                detach()
            }
            return
        }
        consecutivePollFailures = 0
        endpoint = await rest.active
        isAvailable = true

        // Preserve the mode we already learned from each session's socket: the list
        // endpoint does not carry it, and dropping it would flip the mode control
        // back to Ask on every poll.
        let knownModes = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.mode) })
        let knownActivity = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.id, $0.activity) })
        sessions = metas
            .map {
                AgentSession(
                    meta: $0, mode: knownModes[$0.id] ?? .ask,
                    activity: knownActivity[$0.id] ?? nil)
            }
            .rankedForGlance()

        // Remembered so a first spoken prompt on a Mac with a *closed* session still
        // has somewhere sensible to open, rather than demanding a setting first.
        if let directory = metas.first(where: { !$0.cwd.isEmpty })?.cwd {
            lastKnownDirectory = directory
        }

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
        liveSince = 0
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
            // The session respawned: everything we hold describes a dead process,
            // including the history/live boundary — the replacement numbers from 1.
            liveSince = 0
            log.reset()
            ask = nil
            changeSet = AgentChangeSet()

        case .disconnected:
            ask = nil

        case .event(let event):
            apply(event)
        }
    }

    /// Internal rather than private so the replay-vs-live gating is testable: it is
    /// the piece that broke, and it can only be exercised by feeding frames in.
    func apply(_ event: KunaiWire.Event) {
        log.apply(event)
        changeSet.editedPaths = AgentChangeSet.editedPaths(in: log)
        applyActivity(log.currentActivity)

        // History informs the log above; only live frames get to *announce*
        // anything below. `seq == 0` (a frame kunai didn't sequence) counts as
        // live rather than being silently swallowed.
        let isLive = event.seq > liveSince || event.seq == 0

        switch event.kind {
        case .hello:
            liveSince = event.highSeq ?? 0
            if let mode = event.mode { updateMode(KunaiWire.PermissionMode(wire: mode)) }
            // `pending` carries the asks still outstanding at attach — genuinely
            // waiting, however old their sequence numbers are.
            for pendingEvent in event.pending ?? [] { raiseAsk(from: pendingEvent) }

        case .mode:
            guard isLive else { return }
            updateMode(KunaiWire.PermissionMode(wire: event.mode))

        case .permission:
            // A replayed permission was already answered — its resolution is a few
            // frames behind it in the same replay. Raising it would flash a consent
            // card for a question nobody is asking.
            guard isLive else { return }
            raiseAsk(from: event)

        case .permissionResolved:
            if ask?.requestID == event.requestID { ask = nil }

        case .state:
            // **The attached session's state comes from its own socket, in real time.**
            // Deriving it from the 3s poll made the band flip between "working" and
            // "done" on every tick while a turn was starting, which read as the notch
            // flickering rather than as a session running. Replayed state frames are
            // past states, and the present one rides on `hello`.
            guard isLive else { return }
            applyState(KunaiWire.SessionState(wire: event.state))

        case .assistant:
            // Keep the newest thing it said, as one *readable* line — the raw
            // markdown put a literal ``` on the band when a reply opened with a
            // code fence. Live only: a replayed reply belongs to a turn that
            // already had its banner.
            guard isLive else { return }
            if let text = event.blocks?.compactMap(\.text).last,
               let line = AgentReplyLine.compact(text) {
                lastReply = line
                lastReplyRaw = text
            }

        case .result:
            // A replayed result is a turn that finished before we attached; letting
            // it through re-announced every historical turn, once each, on the
            // first dictation.
            guard isLive else { return }
            lastTurnDuration = event.durationMs.map { Double($0) / 1000 }
            // A turn can end without an `assistant` frame reaching us (attached
            // late, or the reply streamed before the socket came up). The banner is
            // the whole of the response, so it must always have a line: fall back to
            // the newest assistant text in the log, then to a plain "Finished".
            if lastReply == nil {
                for entry in log.entries.reversed() {
                    if case .assistant(_, let text) = entry,
                       let line = AgentReplyLine.compact(text) {
                        lastReply = line
                        lastReplyRaw = text
                        break
                    }
                }
            }
            if lastReply == nil { lastReply = "Finished" }
            lastReplyAt = Date()
            // The Settings default: the full reply, without the extra click. Not
            // pinned, so the longer hold still retracts it.
            if expandRepliesByDefault { replyExpanded = true }
            applyState(.idle)

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

    /// The caption the working row shows: what the agent is doing, learned from its
    /// own tool calls. Written onto the attached session so the row and the glance
    /// both read one value.
    private func applyActivity(_ activity: String?) {
        guard let activity,
              let attachedSessionID,
              let index = sessions.firstIndex(where: { $0.id == attachedSessionID })
        else { return }
        sessions[index].activity = activity
    }

    /// Write a live state onto the attached session, so the band tracks the socket
    /// rather than waiting up to three seconds for the next poll.
    private func applyState(_ state: KunaiWire.SessionState) {
        guard let attachedSessionID,
              let index = sessions.firstIndex(where: { $0.id == attachedSessionID })
        else { return }
        sessions[index].state = state
        if state == .running, sessions[index].turnStartedAt == nil {
            sessions[index].turnStartedAt = Int64(Date().timeIntervalSince1970 * 1000)
        }
        if state == .idle { sessions[index].turnStartedAt = nil }
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

    /// The whole point of the key: speak, and the words reach an agent.
    ///
    /// Attaches to the target session first if we are not already on it, then sends.
    /// If there is **no** session at all it starts one and sends the words as its
    /// opening prompt, because "hold a key and talk" has to work on a Mac where
    /// nothing is running yet — otherwise the feature only works for people who
    /// already went somewhere else to start the work.
    ///
    /// Returns false when the words could not be delivered, so the caller can fall
    /// back rather than swallowing them. A dictation that goes nowhere is the one
    /// outcome this path must never produce.
    @discardableResult
    func deliver(prompt text: String, startingIn newSessionDirectory: String?) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isAvailable else { return false }

        if let target = promptTarget {
            if attachedSessionID != target.id {
                openSessionID = target.id
                reconcileAttachment()
                // The socket has to be up before a command can ride it.
                await waitForAttachment()
            }
            guard stream != nil else { return false }
            sendPrompt(trimmed)
            reveal(sessionID: target.id)
            return true
        }

        guard let directory = newSessionDirectory, !directory.isEmpty else { return false }
        guard let id = await rest.createSession(cwd: directory, mode: .ask) else { return false }
        await refresh()
        openSessionID = id
        reconcileAttachment()
        await waitForAttachment()
        guard stream != nil else { return false }
        sendPrompt(trimmed)
        reveal(sessionID: id)
        return true
    }

    /// A directory a session is known to live in, so a first spoken prompt has
    /// somewhere to open without the user configuring anything. Nil on a Mac that has
    /// never run one.
    private(set) var lastKnownDirectory: String?

    /// Which session a spoken prompt belongs to: the one being read, else the one
    /// asking, else the most recently active. "Most recently active" beats "first in
    /// the list" because the list is ranked for *reading* — waiting first — and the
    /// session you last worked in is the one you mean when you start talking.
    var promptTarget: AgentSession? {
        if let openSessionID, let open = sessions.first(where: { $0.id == openSessionID }) {
            return open
        }
        if let asking = askingSession { return asking }
        return sessions.max { a, b in
            (a.turnStartedAt ?? 0, a.id) < (b.turnStartedAt ?? 0, b.id)
        }
    }

    /// Give the **socket** a moment to come up — not merely the object that owns it.
    ///
    /// Waiting on `stream != nil` was the bug: `attach` assigns it synchronously
    /// while the WebSocket is opened later by the pump task, so this returned
    /// immediately and the prompt was sent into a stream with no socket. The queue in
    /// `KunaiEventStream.send` makes that survivable either way; this just avoids
    /// relying on it in the common case.
    private func waitForAttachment(timeout: Duration = .milliseconds(1500)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            guard let stream else { return }  // detached; nothing to wait for
            if await stream.isReady { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Stop the running turn — kunai's interrupt, the same thing Esc does in the
    /// CLI. The band's working row carries the button, because the moment you want
    /// an agent to stop is the moment you are watching it work.
    func interrupt() {
        send(.interrupt())
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
    /// Put the glance into a fixed state for the PNG renderer. `openSessionID` set
    /// means the drill-in form; nil means the session list.
    func seedGlanceForSnapshot(
        sessions: [AgentSession], openSessionID: String? = nil,
        log: AgentTurnLog = AgentTurnLog(), changeSet: AgentChangeSet = AgentChangeSet()
    ) {
        self.sessions = sessions.rankedForGlance()
        self.isAvailable = true
        self.isGlanceOpen = true
        self.openSessionID = openSessionID
        self.log = log
        self.changeSet = changeSet
    }

    /// A finished turn, for the reply-banner render.
    func seedReplyForSnapshot(
        session: AgentSession, reply: String, duration: TimeInterval,
        prompt: String? = nil, turnEvents: [KunaiWire.Event] = []
    ) {
        if let prompt {
            var event = KunaiWire.Event(seq: 1, kind: .user)
            event.text = prompt
            log.apply(event)
        }
        for event in turnEvents { log.apply(event) }
        // Derived, not invented — the same call the live path makes when a turn
        // ends, so the rendered "Changed" rail is the seeded turn's real edits.
        changeSet.editedPaths = AgentChangeSet.editedPaths(in: log)
        sessions = [session]
        isAvailable = true
        isGlanceOpen = true
        revealedAt = Date()
        openSessionID = session.id
        lastReply = AgentReplyLine.compact(reply) ?? reply
        lastReplyRaw = reply
        lastReplyAt = Date()
        lastTurnDuration = duration
    }

    func seedForSnapshot(ask: AgentAsk, sessions: [AgentSession]) {
        self.sessions = sessions.rankedForGlance()
        self.ask = ask
        self.isAvailable = true
        self.attachedSessionID = sessions.first(where: \.isWaiting)?.id ?? sessions.first?.id
    }
}
