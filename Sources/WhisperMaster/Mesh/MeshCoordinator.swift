import Foundation

// MARK: - MeshCoordinator
//
// Owns peer discovery and assembles the observable mesh: this Mac plus the other
// Macs running Whisper Master on the network, each with a privacy-safe display
// name and its current load (latency and proximity arrive in later steps).
// Writes the result into `AppState` on the main actor.
//
// Discovery is injected via the `PeerDiscovering` protocol, so a future
// NAT-traversal / P2P transport replaces only that dependency — this
// coordinator, `MeshPeer`, and the UI stay the same.

@MainActor
final class MeshCoordinator {
    /// How often each peer is re-probed for latency.
    private static let probeInterval: Duration = .seconds(5)

    private let state: AppState
    private let server: RemoteTranscriptionServer
    private var discovery: PeerDiscovering?
    private var discoveredPeers: [DiscoveredPeer] = []
    private var latencyByID: [String: Int] = [:]
    private var proximityByToken: [String: MeshPeer.Proximity] = [:]
    private var probeTask: Task<Void, Never>?
    private var beacon: ProximityBeacon?
    private var scanner: ProximityScanner?

    init(state: AppState, server: RemoteTranscriptionServer) {
        self.state = state
        self.server = server
    }

    func start() {
        let discovery = BonjourPeerDiscovery(onChange: { [weak self] peers in
            Task { @MainActor in self?.ingest(peers) }
        })
        self.discovery = discovery
        discovery.start()

        // Re-render the self row (and its load) whenever our active-session
        // count changes.
        server.onLoadChange = { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }

        startProbing()
        startProximity()
        rebuild()
    }

    func stop() {
        probeTask?.cancel()
        probeTask = nil
        discovery?.stop()
        discovery = nil
        beacon?.stop()
        beacon = nil
        scanner?.stop()
        scanner = nil
    }

    // MARK: - Bluetooth proximity

    private func startProximity() {
        let beacon = ProximityBeacon(token: MeshBluetooth.token(for: LocalPeer.id))
        beacon.start()
        self.beacon = beacon

        let scanner = ProximityScanner(onUpdate: { [weak self] token, proximity in
            Task { @MainActor in self?.proximityDidChange(token, proximity) }
        })
        scanner.start()
        self.scanner = scanner
    }

    private func proximityDidChange(_ token: String, _ proximity: MeshPeer.Proximity) {
        // Only re-render when the coarse bucket actually changes (RSSI updates
        // arrive many times a second with duplicates allowed).
        guard proximityByToken[token] != proximity else { return }
        proximityByToken[token] = proximity
        rebuild()
    }

    // MARK: - Latency probing

    private func startProbing() {
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeAllPeers()
                try? await Task.sleep(for: Self.probeInterval)
            }
        }
    }

    private func probeAllPeers() async {
        for peer in discoveredPeers {
            let id = peer.metadata.id
            latencyByID[id] = await LatencyProbe.measure(peer.endpoint)
        }
        rebuild()
    }

    private func ingest(_ peers: [DiscoveredPeer]) {
        // Drop our own advertised service.
        discoveredPeers = peers.filter { $0.metadata.id != LocalPeer.id }
        rebuild()
    }

    private func rebuild() {
        let selfPeer = MeshPeer(
            id: LocalPeer.id,
            modelFamily: LocalPeer.modelFamily,
            displayName: "This Mac",
            load: server.currentLoad,
            proximity: .unknown,
            latencyMs: nil,
            isSelf: true
        )

        // Number peers per model family by stable id sort, so the generic names
        // ("MacBook Pro 1", "MacBook Pro 2") are deterministic and leak nothing.
        let sorted = discoveredPeers.sorted { $0.metadata.id < $1.metadata.id }
        var perModelCount: [String: Int] = [:]
        let peers: [MeshPeer] = sorted.map { peer in
            let next = (perModelCount[peer.metadata.modelFamily] ?? 0) + 1
            perModelCount[peer.metadata.modelFamily] = next
            return MeshPeer(
                id: peer.metadata.id,
                modelFamily: peer.metadata.modelFamily,
                displayName: "\(peer.metadata.modelFamily) \(next)",
                load: peer.metadata.load,
                proximity: proximityByToken[MeshBluetooth.token(for: peer.metadata.id)] ?? .unknown,
                latencyMs: latencyByID[peer.metadata.id],
                isSelf: false
            )
        }

        state.meshPeers = [selfPeer] + peers
    }
}
