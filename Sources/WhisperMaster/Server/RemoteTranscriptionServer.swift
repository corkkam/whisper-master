import Foundation
import Network

// MARK: - RemoteTranscriptionServer
//
// Advertises a Bonjour transcription service on the local Wi-Fi and runs a
// `RemoteTranscriptionSession` per connecting client. Owned by `AppDelegate`.
// The existing local (menu-bar) recording flow is untouched.
//
// SECURITY POSTURE (this used to be wide open — see `RemotePairing`):
//
//   • Encrypted + authenticated. The listener speaks TLS with a pre-shared key
//     (`RemotePairing`). A client that doesn't hold the key fails the handshake,
//     so unpaired peers never reach session code, and the audio/transcripts on
//     the wire are ciphertext rather than plaintext PCM.
//   • Opt-in. `AppDelegate` starts this only when the user has switched remote
//     dictation on. It used to start unconditionally for every user at launch.
//   • Bounded. `maxConcurrentSessions` is now *enforced* in `accept()`, not just
//     advertised: each session owns its own transcriber (hundreds of MB of
//     models), so unlimited accepts were a trivial memory-exhaustion DoS. Frame
//     sizes are bounded too — see `MessageChannel.maxFramePayloadBytes`.
//
// The advertisement uses an anonymous, generic instance name (never the owner's
// computer name) and carries `PeerMetadata` in its TXT record (id, model family,
// live load) so other Macs in the mesh can list this one and see how busy it is.

@MainActor
final class RemoteTranscriptionServer {
    /// This Mac's load: the number of sessions actively transcribing. Latency
    /// probes (ping-only connections) never count toward it.
    var currentLoad: Int { recordingCount }

    /// Called (on the main actor) whenever `currentLoad` changes.
    var onLoadChange: ((Int) -> Void)?

    private var listener: NWListener?
    private var sessions: [UUID: SessionHandle] = [:]
    private var recordingCount = 0

    /// Keeps the Mac from idle-sleeping while a session is active (and, when the
    /// user opts in, whenever the app is running) so the phone stays reachable.
    private let sleepPreventer = SleepPreventer()
    private var keepAwakeAlways = false

    /// A dedicated queue keeps socket I/O off the main thread (audio frames
    /// arrive continuously while recording).
    private let queue = DispatchQueue(label: "app.whispermaster.server")

    private struct SessionHandle {
        let connection: NWConnection
        let task: Task<Void, Never>
    }

    func start() {
        guard listener == nil else { return }

        // No pairing key means we cannot authenticate or encrypt. Refuse to
        // listen rather than falling back to an open plaintext socket — an
        // unreachable service is a far better failure than a wide-open one.
        guard let parameters = RemotePairing.tlsParameters() else {
            NSLog("RemoteTranscriptionServer: no pairing key available — refusing to start an unauthenticated listener")
            return
        }

        do {
            // Bind a fixed port so an off-LAN client (Tailscale) can reach us at
            // a known host:port; Bonjour still advertises the same port on the LAN.
            let port = NWEndpoint.Port(rawValue: WireProtocol.fixedPort)!
            let listener = try NWListener(using: parameters, on: port)
            listener.service = makeService(load: 0)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    NSLog("RemoteTranscriptionServer: advertising \(WireProtocol.serviceType)")
                case .failed(let error):
                    NSLog("RemoteTranscriptionServer: listener failed: \(error)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("RemoteTranscriptionServer: failed to start listener: \(error)")
        }
    }

    func stop() {
        for handle in sessions.values {
            handle.task.cancel()
            handle.connection.cancel()
        }
        sessions.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        // Enforce the advertised capacity. Each session allocates its own
        // transcriber, so accepting without a bound let any paired-but-hostile
        // (or merely buggy) client exhaust memory by opening connections in a
        // loop. Refusing here costs the client a reconnect; not refusing cost
        // the whole app.
        guard sessions.count < Self.maxConcurrentSessions else {
            NSLog("RemoteTranscriptionServer: at capacity (\(Self.maxConcurrentSessions)) — rejecting connection")
            connection.cancel()
            return
        }

        let id = UUID()
        connection.start(queue: queue)

        let channel = MessageChannel(connection: connection)
        let session = RemoteTranscriptionSession(
            channel: channel,
            onRecordingChange: { [weak self] active in
                Task { @MainActor in self?.recordingDidChange(active) }
            }
        )
        let task = Task { [weak self] in
            await session.run()
            await MainActor.run { self?.endSession(id) }
        }
        sessions[id] = SessionHandle(connection: connection, task: task)
    }

    private func endSession(_ id: UUID) {
        guard let handle = sessions.removeValue(forKey: id) else { return }
        handle.connection.cancel()
    }

    private func recordingDidChange(_ active: Bool) {
        recordingCount = max(0, recordingCount + (active ? 1 : -1))
        // Sessions toggle `active` in balanced true/false pairs, so acquiring on
        // start and releasing on stop refcounts correctly across concurrent ones.
        if active { sleepPreventer.acquire() } else { sleepPreventer.release() }
        loadDidChange()
    }

    /// Opt-in from Settings: hold exactly one persistent wake-lock while enabled,
    /// so the Mac stays reachable even after sitting locked and idle. Idempotent —
    /// the AppDelegate refresh loop calls this every tick.
    func setKeepAwakeAlways(_ on: Bool) {
        guard on != keepAwakeAlways else { return }
        keepAwakeAlways = on
        if on { sleepPreventer.acquire() } else { sleepPreventer.release() }
    }

    /// Re-publish the TXT record with the new load and notify observers.
    private func loadDidChange() {
        listener?.service = makeService(load: recordingCount)
        onLoadChange?(recordingCount)
    }

    /// Build the Bonjour service descriptor: an anonymous instance name plus our
    /// current `PeerMetadata` in the TXT record.
    /// Max concurrent transcription sessions this Mac advertises it will take.
    /// Conservative default; clients balance by headroom (capacity − load).
    static let maxConcurrentSessions = 3

    private func makeService(load: Int) -> NWListener.Service {
        let metadata = PeerMetadata(
            id: LocalPeer.id,
            modelFamily: LocalPeer.modelFamily,
            load: load,
            capacity: Self.maxConcurrentSessions,
            isReady: TranscriberEngine.slidingWindow.isInstalled,
            appVersion: LocalPeer.appVersion
        )
        // Anonymous, unique instance name — never the computer/owner name.
        let name = "Whisper Master " + LocalPeer.id.prefix(8)
        return NWListener.Service(
            name: name,
            type: WireProtocol.serviceType,
            domain: nil,
            txtRecord: metadata.txtRecord()
        )
    }
}
