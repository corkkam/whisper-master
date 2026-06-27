import Foundation
import Network

// MARK: - RemoteTranscriptionServer
//
// Advertises a Bonjour transcription service on the local Wi-Fi and, for each
// connecting iOS client, runs a `RemoteTranscriptionSession`. Owned by
// `AppDelegate`; started once at launch and left advertising for the app's
// lifetime. The existing local (menu-bar) recording flow is untouched.
//
// Prototype policy: one active client at a time — a new connection replaces the
// previous one ("newest wins").

@MainActor
final class RemoteTranscriptionServer {
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var activeSessionTask: Task<Void, Never>?

    /// A dedicated queue keeps socket I/O off the main thread (audio frames
    /// arrive continuously while recording).
    private let queue = DispatchQueue(label: "app.whispermaster.server")

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(type: WireProtocol.serviceType)
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
        activeSessionTask?.cancel()
        activeConnection?.cancel()
        listener?.cancel()
        activeConnection = nil
        activeSessionTask = nil
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        // Newest wins: drop any previous client.
        activeSessionTask?.cancel()
        activeConnection?.cancel()

        activeConnection = connection
        connection.start(queue: queue)

        let channel = MessageChannel(connection: connection)
        let session = RemoteTranscriptionSession(channel: channel)
        activeSessionTask = Task {
            await session.run()
            await MainActor.run { [weak self] in
                // Only clear if this is still the active connection.
                if self?.activeConnection === connection {
                    self?.activeConnection?.cancel()
                    self?.activeConnection = nil
                    self?.activeSessionTask = nil
                }
            }
        }
    }
}
