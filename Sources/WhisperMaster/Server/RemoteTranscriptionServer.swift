import Foundation
import Network

// MARK: - RemoteTranscriptionServer
//
// Advertises a Bonjour transcription service on the local Wi-Fi and runs a
// `RemoteTranscriptionSession` per connecting client. Owned by `AppDelegate`;
// started once at launch and left advertising for the app's lifetime. The
// existing local (menu-bar) recording flow is untouched.
//
// The advertisement uses an anonymous, generic instance name (never the owner's
// computer name) and carries `PeerMetadata` in its TXT record (id, model family,
// live load) so other Macs in the mesh can list this one and see how busy it is.
//
// Multiple concurrent sessions are tracked so `currentLoad` is meaningful (and to
// set up later load-balancing). Each session owns its own transcriber, so several
// at once cost real memory/CPU — fine for a handful of clients; cap if needed.

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

    /// A dedicated queue keeps socket I/O off the main thread (audio frames
    /// arrive continuously while recording).
    private let queue = DispatchQueue(label: "app.whispermaster.server")

    private struct SessionHandle {
        let connection: NWConnection
        let task: Task<Void, Never>
    }

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
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
        loadDidChange()
    }

    /// Re-publish the TXT record with the new load and notify observers.
    private func loadDidChange() {
        listener?.service = makeService(load: recordingCount)
        onLoadChange?(recordingCount)
    }

    /// Build the Bonjour service descriptor: an anonymous instance name plus our
    /// current `PeerMetadata` in the TXT record.
    private func makeService(load: Int) -> NWListener.Service {
        let metadata = PeerMetadata(
            id: LocalPeer.id,
            modelFamily: LocalPeer.modelFamily,
            load: load,
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
