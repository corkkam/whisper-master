import Foundation

/// A Mac in the mesh, as shown in the UI. Privacy-safe: identified by an
/// anonymous id and a generic display name, never the owner's machine name.
struct MeshPeer: Identifiable, Equatable {
    let id: String
    let modelFamily: String
    /// Generic, deterministic label ("MacBook Pro 2") or "This Mac" for self.
    let displayName: String
    /// Active remote sessions on that Mac (its current load).
    let load: Int
    let proximity: Proximity
    /// Round-trip latency in milliseconds, once measured (step 2).
    let latencyMs: Int?
    let isSelf: Bool

    /// Rough physical closeness from Bluetooth RSSI (step 3). `.unknown` until measured.
    enum Proximity: Equatable {
        case unknown, near, medium, far
    }
}
