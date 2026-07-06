import Foundation
import Network

// MARK: - Transport abstraction
//
// The mesh is intentionally transport-agnostic. Today peers are found and
// reached over Bonjour on the local Wi-Fi; later, relay / NAT-traversal / P2P
// transports can be added as new `PeerEndpoint` cases and new `PeerDiscovering`
// implementations — without changing `MeshCoordinator`, `MeshPeer`, or the UI.

/// How a discovered peer can be reached.
enum PeerEndpoint: Equatable {
    case bonjour(NWEndpoint)
    // Future: case relay(RelayRoute), case direct(host:port) for NAT traversal.
}

/// A peer surfaced by a discovery transport: its published metadata plus how to
/// reach it.
struct DiscoveredPeer: Equatable {
    let metadata: PeerMetadata
    let endpoint: PeerEndpoint
}

/// Abstraction over "find peers." `BonjourPeerDiscovery` is the LAN
/// implementation; a future relay/NAT-traversal discovery conforms to the same
/// protocol and `MeshCoordinator` is unchanged.
protocol PeerDiscovering: AnyObject {
    func start()
    func stop()
}

// MARK: - BonjourPeerDiscovery
//
// LAN peer discovery via Bonjour (`NWBrowser`), mirroring the iOS client's
// `ServerDiscovery`. Reads each peer's TXT metadata and reports the current set
// whenever it changes.

final class BonjourPeerDiscovery: PeerDiscovering, @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "app.whispermaster.mesh.discovery")
    private let onChange: @Sendable ([DiscoveredPeer]) -> Void

    init(onChange: @escaping @Sendable ([DiscoveredPeer]) -> Void) {
        self.onChange = onChange
    }

    /// This Mac's own advertised instance name, so we can skip it in results.
    private static var ownServiceName: String { "Whisper Master " + LocalPeer.id.prefix(8) }

    func start() {
        guard browser == nil else { return }
        // Use the TXT-record descriptor so browse results carry our metadata.
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: WireProtocol.serviceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                NSLog("BonjourPeerDiscovery: browser failed: \(error)")
            }
        }
        browser.browseResultsChangedHandler = { [onChange] results, _ in
            onChange(results.compactMap(Self.peer(from:)))
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private static func peer(from result: NWBrowser.Result) -> DiscoveredPeer? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        // Skip our own advertised service.
        guard name != ownServiceName else { return nil }

        // Prefer TXT metadata; if the browse result doesn't carry it, still
        // surface the peer using the anonymous service name as identity so it
        // appears (metadata enriches when available).
        let metadata: PeerMetadata
        if case let .bonjour(txtRecord) = result.metadata,
           let decoded = PeerMetadata(txtRecord: txtRecord) {
            metadata = decoded
        } else {
            // TXT not attached to this browse result — surface the peer using
            // the anonymous service name as identity; metadata enriches later.
            metadata = PeerMetadata(
                id: name, modelFamily: "Mac", load: 0, capacity: 1, isReady: false, appVersion: "0"
            )
        }
        return DiscoveredPeer(metadata: metadata, endpoint: .bonjour(result.endpoint))
    }
}
