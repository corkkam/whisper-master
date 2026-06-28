import Foundation
import Network

// MARK: - PeerMetadata
//
// What each Mac publishes about itself (in its Bonjour TXT record today) and
// what peers decode on discovery. Transport-neutral: a future relay transport
// would carry the same fields through a different channel.

struct PeerMetadata: Equatable {
    let id: String
    let modelFamily: String
    let load: Int
    let appVersion: String

    private enum Key {
        static let id = "id"
        static let model = "model"
        static let load = "load"
        static let version = "v"
    }

    init(id: String, modelFamily: String, load: Int, appVersion: String) {
        self.id = id
        self.modelFamily = modelFamily
        self.load = load
        self.appVersion = appVersion
    }

    /// Decode from a discovered Bonjour TXT record. Returns nil if the record
    /// isn't one of ours (no id).
    init?(txtRecord: NWTXTRecord) {
        func value(_ key: String) -> String? {
            if case let .string(string) = txtRecord.getEntry(for: key) { return string }
            return nil
        }
        guard let id = value(Key.id) else { return nil }
        self.id = id
        self.modelFamily = value(Key.model) ?? "Mac"
        self.load = Int(value(Key.load) ?? "") ?? 0
        self.appVersion = value(Key.version) ?? "0"
    }

    func txtRecord() -> NWTXTRecord {
        NWTXTRecord([
            Key.id: id,
            Key.model: modelFamily,
            Key.load: String(load),
            Key.version: appVersion,
        ])
    }
}
