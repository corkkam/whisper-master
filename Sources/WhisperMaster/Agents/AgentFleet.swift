import Foundation

/// Every machine's sessions, merged into one list.
///
/// Split out of `AgentSurfaceController` because it is a whole concern on its own:
/// discover the machines, hold a fleet socket against each, keep each one's sessions
/// in its own bucket, and hand the controller a single merged list. The controller
/// stays about *one* session — the one being read — which is what it was already good
/// at.
///
/// **One socket per machine, never per session.** That is kunai's own design ("the
/// fleet socket: one per machine"), and it scales with how many Macs and Linux boxes
/// you run rather than with how many agents are running on them.
@MainActor
final class AgentFleet {

    /// Called whenever the merged list changes, with sessions from every machine.
    var onSessions: (([AgentSession]) -> Void)?

    /// Machines as `GET /api/machines` last reported them.
    private(set) var machines: [KunaiMachine] = []

    /// Each machine's sessions, kept apart so one machine going quiet cannot erase
    /// another's. Merging a single flat list would mean the last push to arrive
    /// silently deleted every other machine's agents.
    private var buckets: [String: [AgentSession]] = [:]

    private var streams: [String: KunaiFleetStream] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    /// The endpoint each machine's sockets are opened against, so a session on a
    /// remote machine attaches to *that* machine rather than to this one.
    private(set) var endpoints: [String: KunaiEndpoint] = [:]

    /// The machine a session belongs to, for the surfaces that name it.
    private(set) var machineOf: [String: KunaiMachine] = [:]

    func endpoint(forSession sessionID: String) -> KunaiEndpoint? {
        guard let machine = machineOf[sessionID] else { return nil }
        return endpoints[machine.id]
    }

    /// Take the machine list and open, move, or close a fleet socket for each.
    ///
    /// `local` is whatever discovery settled on for this Mac; a machine flagged
    /// `self` uses it rather than its advertised tailnet URL.
    func reconcile(machines: [KunaiMachine], local: KunaiEndpoint?) {
        self.machines = machines
        var wanted: [String: KunaiEndpoint] = [:]
        for machine in machines {
            guard let endpoint = machine.endpoint(local: local) else { continue }
            wanted[machine.id] = endpoint
        }

        // Close sockets for machines that are gone, and for any whose address moved.
        for (id, stream) in streams where wanted[id]?.baseURL != endpoints[id]?.baseURL {
            tasks[id]?.cancel()
            tasks[id] = nil
            streams[id] = nil
            buckets[id] = nil
            Task { await stream.disconnect() }
        }

        endpoints = wanted
        for (id, endpoint) in wanted where streams[id] == nil {
            open(machineID: id, endpoint: endpoint)
        }
        rebuild()
    }

    /// Drop everything. The surface going dark must not leave sockets open.
    func stop() {
        for (_, task) in tasks { task.cancel() }
        let closing = Array(streams.values)
        tasks = [:]
        streams = [:]
        buckets = [:]
        endpoints = [:]
        machineOf = [:]
        machines = []
        Task { for stream in closing { await stream.disconnect() } }
    }

    /// Whether any machine's socket is up. The REST poll slows down when one is.
    var isPushing: Bool { !streams.isEmpty }

    private func open(machineID: String, endpoint: KunaiEndpoint) {
        let stream = KunaiFleetStream(endpoint: endpoint)
        streams[machineID] = stream
        tasks[machineID] = Task { [weak self] in
            let frames = await stream.connect()
            for await frame in frames {
                guard let self else { return }
                switch frame {
                case .sessions(let metas):
                    self.receive(metas, from: machineID)
                case .disconnected:
                    self.dropped(machineID)
                }
            }
        }
    }

    private func receive(_ metas: [KunaiWire.SessionMeta], from machineID: String) {
        let machine = machines.first { $0.id == machineID }
        buckets[machineID] = metas.map { meta in
            var session = AgentSession(meta: meta)
            // A session away from this Mac says so, because "kunai needs you" means
            // something different when kunai is on the box in the other room.
            session.machineID = machineID
            session.machineLabel = (machine?.isSelf ?? true) ? "" : (machine?.shortLabel ?? "")
            return session
        }
        rebuild()
    }

    /// A machine's socket went away. **Its sessions stay** until the machine itself
    /// leaves the list: a dropped socket is a network blip far more often than it is
    /// a machine that stopped existing, and clearing the bucket would make every
    /// agent on it vanish from the notch and then come back.
    private func dropped(_ machineID: String) {
        tasks[machineID]?.cancel()
        tasks[machineID] = nil
        streams[machineID] = nil
    }

    private func rebuild() {
        var merged: [AgentSession] = []
        var owner: [String: KunaiMachine] = [:]
        // Deterministic order: this machine's sessions first, then the others by
        // label, so the list does not reshuffle every time a push lands.
        let ordered = machines.sorted { a, b in
            if a.isSelf != b.isSelf { return a.isSelf }
            return a.shortLabel.localizedCaseInsensitiveCompare(b.shortLabel) == .orderedAscending
        }
        for machine in ordered {
            for session in buckets[machine.id] ?? [] {
                merged.append(session)
                owner[session.id] = machine
            }
        }
        machineOf = owner
        onSessions?(merged)
    }
}
