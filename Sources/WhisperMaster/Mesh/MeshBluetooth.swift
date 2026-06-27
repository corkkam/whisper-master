import CoreBluetooth

// MARK: - MeshBluetooth
//
// Shared constants for the Bluetooth-LE proximity layer. Each Mac advertises a
// fixed mesh service UUID with a short token (the first 8 chars of its peer id)
// as the BLE local name — the full peer id (36 chars) doesn't fit in a BLE
// advertisement alongside a 128-bit service UUID. Peers correlate the token back
// to the Bonjour-discovered peer by id prefix.

enum MeshBluetooth {
    /// Private service UUID identifying a Whisper Master proximity beacon.
    static let serviceUUID = CBUUID(string: "B6F8D4C2-9E3A-4F1B-8C7D-2A5E9F0B1C3D")

    /// Short token advertised over BLE and used to match a beacon to a peer id.
    static func token(for peerID: String) -> String { String(peerID.prefix(8)) }

    /// Map a raw RSSI (dBm) to a coarse proximity bucket. Thresholds are rough —
    /// RSSI↔distance is noisy and environment-dependent.
    static func proximity(forRSSI rssi: Int) -> MeshPeer.Proximity {
        switch rssi {
        case let value where value >= -55: return .near
        case let value where value >= -75: return .medium
        default: return .far
        }
    }
}
