import AppKit
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
/// - **Two sockets, never N — the shape kunai's own web app uses.** `/ws/fleet`
///   carries every session's state, pushed and coalesced, so knowing about all of
///   them costs one connection. `/ws/app/{id}` carries the conversation you are
///   reading. A *second* per-session socket opens only for a neighbour blocked on a
///   permission, because the fleet push says which session is asking but not what it
///   asked. The REST poll survives underneath as the fallback that notices a server
///   coming back.
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

    /// Put the whole answer on the clipboard — the raw markdown, not the one-line
    /// presentation, because what you copy out of a reply is the thing you paste
    /// into a commit message or a ticket. The band is the only place this text
    /// exists (a turn deliberately skips `appendHistory`), so without this the only
    /// way to keep it is to go to the browser.
    @discardableResult
    func copyLastReply() -> Bool {
        guard let text = lastReplyRaw ?? lastReply, !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// Show a session's tail because something just went to it.
    ///
    /// This is what stops a spoken prompt from disappearing: the words are suppressed
    /// from the paste, so without a surface the user has no evidence they went
    /// anywhere at all.
    /// `adoptExistingReply` decides whether the replay kunai sends on attach may
    /// populate the reply band. It is **false for a send** — the previous turn's
    /// answer replaying as though it were this one's is exactly the ghost that used
    /// to flash up — and **true when you deliberately open a session**, which is the
    /// only way to see what an agent said while you were looking elsewhere.
    func reveal(sessionID: String, adoptExistingReply: Bool = false) {
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
        adoptReplayedReply = adoptExistingReply
        reconcileAttachment()
    }

    /// Set while a deliberately-opened session's replay is still arriving. Cleared by
    /// the first live frame, so it can only ever colour the history.
    private var adoptReplayedReply = false

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
        guard let id = openSessionID ?? attachedSessionID else { return nil }
        // The web app for a remote session lives on *its* machine.
        guard let base = fleet.endpoint(forSession: id) ?? endpoint else { return nil }
        return base.baseURL.appendingPathComponent(id)
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
    /// How often the REST list is polled. It starts fast and **drops to a slow
    /// heartbeat as soon as the fleet socket delivers**, because the push is then
    /// the real source and the poll is only there to notice the server coming back.
    var pollInterval: Duration = KunaiPollCadence.live
    static let livePollInterval = KunaiPollCadence.live
    static let backgroundPollInterval = KunaiPollCadence.background

    /// Every machine's sessions, merged. One fleet socket per machine, which is
    /// kunai's own design — sessions live on the machine that runs them, so a client
    /// that talks only to its own Mac sees only its own Mac.
    private let fleet = AgentFleet()
    private var fleetWired = false

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
        fleet.stop()
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
        // Machines first: sessions live on the machine that runs them, so this is
        // what turns "the agents on this Mac" into "the agents you are running".
        let machines = await rest.machines()
        reconcileFleet(machines: machines)

        // The poll's own list is the *local* machine's, and it is only the fallback:
        // once any fleet socket is pushing, applying it here would delete every
        // remote machine's sessions on every pass. An older kunai with no
        // `/api/machines` lands here too, and still works, as one machine.
        if !fleet.isPushing {
            applySessions(metas.map { AgentSession(meta: $0) })
        }
    }

    /// Fold a merged session list into state.
    ///
    /// The fleet push and the REST poll both arrive here, so the two can never grow
    /// different behaviour. Everything the list endpoint does not carry — the mode we
    /// learned from a socket, the activity, the live state of the session we are
    /// attached to — is re-applied on top.
    private func applySessions(_ incoming: [AgentSession]) {
        let knownModes = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.mode) })
        let knownActivity = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.id, $0.activity) })
        sessions = incoming
            .map { session in
                var session = session
                session.mode = knownModes[session.id] ?? session.mode
                session.activity = session.activity ?? knownActivity[session.id] ?? nil
                // The attached socket is still the authority on its own session: the
                // fleet push coalesces, so it can land a hair behind a state frame we
                // already have.
                if let live = socketStates[session.id] {
                    session.state = live
                    if live == .idle { session.turnStartedAt = nil }
                }
                return session
            }
            .rankedForGlance()

        // Remembered so a first spoken prompt on a Mac with a *closed* session still
        // has somewhere sensible to open, rather than demanding a setting first.
        if let local = sessions.first(where: { !$0.isRemote && !$0.cwd.isEmpty })?.cwd {
            lastKnownDirectory = local
        }

        // What the sessions we are *not* watching have been doing.
        if let event = attention.update(sessions: sessions, watching: attendedSessionID) {
            nudge = event
            nudgeAt = Date()
        }

        reconcileAttachment()
        reconcileAskAttachment()
    }

    // MARK: The fleet

    /// Wire the fleet up once, then keep its machine list current. Both are cheap and
    /// idempotent, so the poll can just call this every pass.
    private func reconcileFleet(machines: [KunaiMachine]) {
        if !fleetWired {
            fleetWired = true
            fleet.onSessions = { [weak self] merged in
                self?.receiveFleet(merged)
            }
        }
        fleet.reconcile(machines: machines, local: endpoint)
        // A push is proof the server is up, so the poll can go back to sleep.
        pollInterval = fleet.isPushing ? Self.backgroundPollInterval : Self.livePollInterval
    }

    private func receiveFleet(_ merged: [AgentSession]) {
        isAvailable = true
        consecutivePollFailures = 0
        applySessions(merged)
    }

    // MARK: The asking session's socket

    /// A **second** socket, opened only for a session that is blocked on a permission
    /// while you are reading a different one.
    ///
    /// This is the one place more than one socket earns its keep, and it is two, not
    /// N. The fleet push says *which* session is asking, but not what it is asking —
    /// the question and its arguments only exist on that session's own stream. Without
    /// this the card could not be raised at all until you tapped across, which is a
    /// blocked machine waiting on a person who has to notice a hint first.
    ///
    /// It carries **permissions only**. The transcript, the reply, the change set and
    /// the mode all stay with the focused session, so nothing here can make the band
    /// show two conversations at once.
    private var askStream: KunaiEventStream?
    private var askPumpTask: Task<Void, Never>?
    private(set) var askSessionID: String?

    /// Open, move, or close the second socket to match who is actually asking.
    private func reconcileAskAttachment() {
        // Whoever is blocked and is *not* the session we already have a socket on.
        let wanted = sessions.first {
            $0.state == .awaitingPermission && $0.id != attachedSessionID
        }?.id
        guard wanted != askSessionID else { return }
        detachAsk()
        guard let wanted else { return }

        let askEndpoint = fleet.endpoint(forSession: wanted) ?? endpoint
        guard let askEndpoint else { return }
        let stream = KunaiEventStream(endpoint: askEndpoint, sessionID: wanted)
        askStream = stream
        askSessionID = wanted
        askPumpTask = Task { [weak self] in
            let frames = await stream.connect()
            for await frame in frames {
                guard let self else { return }
                await self.handleAsk(frame, from: wanted)
            }
        }
    }

    private func detachAsk() {
        askPumpTask?.cancel()
        askPumpTask = nil
        let closing = askStream
        askStream = nil
        // Only clear the card if it is the one this socket raised — the focused
        // session's own question must survive its neighbour going away.
        if ask != nil, askOwner == askSessionID { ask = nil; askOwner = nil }
        askSessionID = nil
        Task { await closing?.disconnect() }
    }

    /// Which session raised the card currently on screen. The answer has to go back
    /// down the socket it came from, and with two open that is no longer implied.
    private(set) var askOwner: String?

    private func handleAsk(_ frame: KunaiEventStream.Frame, from sessionID: String) {
        guard case .event(let event) = frame else { return }
        switch event.kind {
        case .hello:
            // Only what is *still* outstanding. A replayed permission from this
            // session's history was answered long ago.
            for pending in event.pending ?? [] { raiseAsk(from: pending, owner: sessionID) }
        case .permission:
            raiseAsk(from: event, owner: sessionID)
        case .permissionResolved:
            // Answered somewhere else — kunai's web app, another client, a timeout.
            if ask?.requestID == event.requestID { ask = nil; askOwner = nil }
        default:
            return
        }
    }

    /// The machines kunai knows about. Read by Settings to say what the notch can see.
    var machines: [KunaiMachine] { fleet.machines }

    // MARK: Other sessions

    /// The session the band is currently speaking for — the one whose events are
    /// already reaching the user. Everything else is a candidate for a nudge.
    private var attendedSessionID: String? { openSessionID ?? attachedSessionID }

    /// Whether any session that is not on screen is blocked on a permission. This is
    /// what the menu bar reflects: a machine stopped, waiting, out of sight.
    var otherSessionNeedsYou: Bool {
        sessions.contains { $0.id != attendedSessionID && $0.state == .awaitingPermission }
    }

    var runningSessionCount: Int { sessions.count(where: { $0.state == .running }) }

    /// The one-line interruption raised for another session, and when it was raised.
    private(set) var nudge: AgentAttention.Event?
    private(set) var nudgeAt: Date?
    private var attention = AgentAttention()

    /// How long a nudge stays up. Short: it is a pointer, not the content.
    static let nudgeHold: TimeInterval = 7

    /// Hold the nudge's clock while something else has the band. Same trick the due
    /// reminder uses — a window that runs down while it is suppressed is a message
    /// the user never got.
    func holdNudge() {
        guard nudge != nil else { return }
        nudgeAt = Date()
    }

    func dismissNudge() {
        nudge = nil
        nudgeAt = nil
    }

    /// Move attention to another session: what tapping a nudge does.
    ///
    /// It **switches rather than fans out** — one socket, moved deliberately. That is
    /// the whole design: we never yank the user to another agent on our own, and we
    /// never try to render a session we are not attached to. The tap is the consent,
    /// and the surfaces that follow (its card, its reply) are the ones that already
    /// work.
    func focus(sessionID: String) {
        dismissNudge()
        reveal(sessionID: sessionID, adoptExistingReply: true)
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
        // **A session's socket belongs to its machine.** Attaching everything to this
        // Mac's kunai worked only while every session was on this Mac; a session on
        // another box has to be reached at that box's own address.
        guard let endpoint = fleet.endpoint(forSession: sessionID) ?? endpoint else { return }
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
            // …including whatever the dead process last said its state was, or the
            // poll would keep being overruled by it.
            if let attachedSessionID { socketStates[attachedSessionID] = nil }

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
        if isLive {
            adoptReplayedReply = false
        } else {
            adoptReplayFromLogIfWanted()
        }

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

    /// Show what this session already said, from the replay rather than from a live
    /// frame. Only for a session opened on purpose, and only while it is idle — doing
    /// it for a running session would put a finished reply on the band beside an agent
    /// that is still working.
    private func adoptReplayFromLogIfWanted() {
        guard adoptReplayedReply, lastReply == nil else { return }
        guard openSession?.state == .idle else { return }
        guard let raw = log.lastAssistantText else { return }
        lastReplyRaw = raw
        lastReply = AgentReplyLine.compact(raw) ?? raw
        // The clock starts when *you* opened it: this is reading time for something
        // that finished a while ago, not a fresh announcement.
        lastReplyAt = Date()
        replyExpanded = expandRepliesByDefault
    }

    /// `owner` is the session the question came from. With a second socket open for
    /// a blocked neighbour, "which session is this card from" stops being implied by
    /// the one attachment — and the answer has to go back down the socket that asked.
    private func raiseAsk(from event: KunaiWire.Event, owner: String? = nil) {
        guard event.kind == .permission || event.requestID != nil else { return }
        let from = owner ?? attachedSessionID
        let title = sessions.first { $0.id == from }?.repo ?? askingSession?.repo ?? ""
        guard let built = AgentAsk.make(from: event, sessionTitle: title) else { return }
        // First question wins. A second card stacked on the first would hide which
        // one the buttons answer.
        guard ask == nil else { return }
        ask = built
        askOwner = from
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
        // A turn starting is what makes the previous turn's answer old news. Doing it
        // here as well as in `sendPrompt` covers the turn someone started from the
        // terminal or kunai's web app, which this client never saw sent.
        if state == .running, sessions[index].state != .running {
            lastReply = nil
            lastReplyRaw = nil
        }
        sessions[index].state = state
        if state == .running, sessions[index].turnStartedAt == nil {
            sessions[index].turnStartedAt = Int64(Date().timeIntervalSince1970 * 1000)
        }
        if state == .idle { sessions[index].turnStartedAt = nil }
        socketStates[attachedSessionID] = state
    }

    /// Each session's state as its **socket** last reported it, keyed by id. The poll
    /// replaces `sessions` wholesale every three seconds, so without this the live
    /// state was overwritten by one up to three seconds old — a finished turn flipped
    /// back to `running`, which took the reply off the band until the next round trip.
    ///
    /// Keyed rather than a single value on purpose: a lone `socketState` would be
    /// applied to whichever session the poll happened to be describing, so attaching
    /// to a second session made the first one's state follow it around.
    private var socketStates: [String: KunaiWire.SessionState] = [:]

    private func updateMode(_ mode: KunaiWire.PermissionMode) {
        guard let attachedSessionID,
              let index = sessions.firstIndex(where: { $0.id == attachedSessionID })
        else { return }
        sessions[index].mode = mode
    }

    // MARK: Actions

    /// Answer an approval card.
    func resolve(_ ask: AgentAsk, allow: Bool, always: Bool = false) {
        sendToAskOwner(.permission(requestID: ask.requestID, allow: allow, always: always))
        self.ask = nil
        askOwner = nil
    }

    /// Answer a choice card. Denying is still an allow-with-no-answer in kunai's
    /// model only when the user picked something; a dismissal is a deny.
    func answer(_ choice: AgentChoice, question: AgentChoice.Question, selected: [String]) {
        guard !selected.isEmpty else {
            sendToAskOwner(.permission(requestID: choice.requestID, allow: false))
            ask = nil
            askOwner = nil
            return
        }
        sendToAskOwner(.permission(
            requestID: choice.requestID, allow: true,
            answers: AgentChoice.answers(for: question, selected: selected)))
        ask = nil
        askOwner = nil
    }

    /// Send a dictated prompt to the session the panel is pointed at.
    func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Open the turn locally rather than waiting for kunai to echo the `user`
        // frame: until the boundary moves, the log still believes the previous turn
        // is running and the bezel names a command from minutes ago.
        log.beginTurn(prompt: trimmed)
        // Last turn's answer belongs to last turn. Leaving it set meant a new prompt
        // could land while the finished reply was still on the band.
        lastReply = nil
        lastReplyRaw = nil
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

    /// Answer the card down whichever socket raised it. Sending every answer on the
    /// focused stream would resolve a request id the focused session has never heard
    /// of, and leave the blocked one blocked.
    private func sendToAskOwner(_ command: KunaiWire.Command) {
        if let askOwner, askOwner == askSessionID, let askStream {
            Task { await askStream.send(command) }
            return
        }
        send(command)
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

    func seedNudgeForSnapshot(_ event: AgentAttention.Event, sessions: [AgentSession]) {
        self.sessions = sessions.rankedForGlance()
        self.isAvailable = true
        self.nudge = event
        self.nudgeAt = Date()
    }

    func seedForSnapshot(ask: AgentAsk, sessions: [AgentSession]) {
        self.sessions = sessions.rankedForGlance()
        self.ask = ask
        self.isAvailable = true
        self.attachedSessionID = sessions.first(where: \.isWaiting)?.id ?? sessions.first?.id
    }
}
