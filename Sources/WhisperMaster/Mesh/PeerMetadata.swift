import Foundation
import Network

// MARK: - PeerMetadata
//
// What each Mac publishes about itself (in its Bonjour TXT record today) and
// what peers/clients decode on discovery. Transport-neutral.
//
// IMPORTANT: the TXT key strings here must stay in sync with the iOS client's
// `ServerInfo` decoder (`whisper-master-ios`, Sources/Shared/ServerDiscovery.swift).
// Decoding is default-safe so an older peer missing newer keys still works.

struct PeerMetadata: Equatable {
    let id: String
    let modelFamily: String
    /// Active transcription sessions right now (this Mac's current load).
    let load: Int
    /// Max concurrent sessions this Mac will accept (its capacity).
    let capacity: Int
    /// Whether the engine model is present on disk (no ~640 MB download needed).
    let isReady: Bool
    let appVersion: String

    private enum Key {
        static let id = "id"
        static let model = "model"
        static let load = "load"
        static let capacity = "cap"
        static let ready = "ready"
        static let version = "v"
    }

    init(
        id: String,
        modelFamily: String,
        load: Int,
        capacity: Int,
        isReady: Bool,
        appVersion: String
    ) {
        self.id = id
        self.modelFamily = modelFamily
        self.load = load
        self.capacity = capacity
        self.isReady = isReady
        self.appVersion = appVersion
    }

    /// Decode from a discovered Bonjour TXT record. Returns nil if the record
    /// isn't one of ours (no id). Newer fields default safely for older peers.
    init?(txtRecord: NWTXTRecord) {
        func value(_ key: String) -> String? {
            if case let .string(string) = txtRecord.getEntry(for: key) { return string }
            return nil
        }
        guard let id = value(Key.id) else { return nil }
        self.id = id
        self.modelFamily = value(Key.model) ?? "Mac"
        self.load = Int(value(Key.load) ?? "") ?? 0
        self.capacity = Int(value(Key.capacity) ?? "") ?? 1
        self.isReady = (value(Key.ready) == "1")
        self.appVersion = value(Key.version) ?? "0"
    }

    func txtRecord() -> NWTXTRecord {
        NWTXTRecord([
            Key.id: id,
            Key.model: modelFamily,
            Key.load: String(load),
            Key.capacity: String(capacity),
            Key.ready: isReady ? "1" : "0",
            Key.version: appVersion,
        ])
    }
}
