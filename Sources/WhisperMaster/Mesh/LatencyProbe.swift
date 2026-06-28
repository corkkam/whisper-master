import Foundation
import Network

// MARK: - LatencyProbe
//
// Measures application round-trip time to a mesh peer: open a connection, and
// once it's ready, send a `.ping(nonce)` and time the matching `.pong`. The
// timer starts *after* the connection is established, so it reflects message
// round-trip rather than TCP setup.
//
// Transport-agnostic at the entry point — a future relay / NAT-traversal
// `PeerEndpoint` adds a case here without changing callers.

enum LatencyProbe {
    /// Round-trip latency to `endpoint` in milliseconds, or nil on failure/timeout.
    static func measure(_ endpoint: PeerEndpoint, timeout: Duration = .seconds(2)) async -> Int? {
        await withTimeoutOrNil(timeout) {
            switch endpoint {
            case .bonjour(let nwEndpoint):
                return await roundTrip(to: nwEndpoint)
            }
        }
    }

    private static func roundTrip(to endpoint: NWEndpoint) async -> Int? {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let channel = MessageChannel(connection: connection)
        let queue = DispatchQueue(label: "app.whispermaster.mesh.probe")

        guard await waitForReady(connection, queue: queue) else {
            connection.cancel()
            return nil
        }

        let nonce = UInt32.random(in: .min ... .max)
        let start = DispatchTime.now()
        do {
            try await channel.send(control: ClientControl.ping(nonce: nonce))
            while true {
                let frame = try await channel.receiveFrame()
                guard frame.kind == .control else { continue }
                if case let .pong(received) = try ServerControl.decode(frame.payload), received == nonce {
                    break
                }
            }
        } catch {
            connection.cancel()
            return nil
        }

        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        connection.cancel()
        return Int(elapsedNs / 1_000_000)
    }

    private static func waitForReady(_ connection: NWConnection, queue: DispatchQueue) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setIfUnset() { continuation.resume(returning: true) }
                case .failed, .cancelled:
                    if resumed.setIfUnset() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func withTimeoutOrNil(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async -> Int?
    ) async -> Int? {
        await withTaskGroup(of: Int?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Tiny thread-safe one-shot flag, so a connection's state handler resumes its
/// continuation exactly once.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isSet { return false }
        isSet = true
        return true
    }
}
