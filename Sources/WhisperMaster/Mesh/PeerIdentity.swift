import Foundation
import IOKit.ps

// MARK: - LocalPeer
//
// This Mac's identity in the mesh. The id is a persisted random UUID —
// deliberately NOT derived from the hostname, serial, or owner's name, so peers
// never learn anything personal. It is transport-independent: the same id
// identifies this Mac whether it's reached over Bonjour today or a relay / NAT
// traversal transport in the future.

enum LocalPeer {
    private static let idDefaultsKey = "WhisperMaster.mesh.peerId.v1"

    /// Stable, anonymous identifier for this Mac, generated once and persisted.
    /// `WHISPERMASTER_MESH_PEER_ID` overrides it — useful for running a second
    /// instance on one Mac to exercise the mesh (two instances would otherwise
    /// share the persisted id and filter each other out as "self").
    static let id: String = {
        if let override = ProcessInfo.processInfo.environment["WHISPERMASTER_MESH_PEER_ID"],
           !override.isEmpty {
            return override
        }
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: idDefaultsKey) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: idDefaultsKey)
        return fresh
    }()

    /// Coarse, privacy-safe device family (e.g. "MacBook Pro", "Mac mini").
    static let modelFamily: String = DeviceModel.family()

    static let appVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
}

// MARK: - DeviceModel
//
// Best-effort, privacy-safe device family. Intel and older Macs report a
// descriptive hardware identifier ("MacBookPro18,3"); Apple Silicon reports an
// opaque one ("Mac14,2"), so we fall back to a laptop/desktop split via the
// presence of a battery.

enum DeviceModel {
    static func family() -> String {
        let identifier = hardwareIdentifier()
        let descriptive: [(prefix: String, name: String)] = [
            ("MacBookPro", "MacBook Pro"),
            ("MacBookAir", "MacBook Air"),
            ("MacBook", "MacBook"),
            ("Macmini", "Mac mini"),
            ("MacPro", "Mac Pro"),
            ("iMacPro", "iMac Pro"),
            ("iMac", "iMac"),
            ("MacStudio", "Mac Studio"),
        ]
        for entry in descriptive where identifier.hasPrefix(entry.prefix) {
            return entry.name
        }
        return hasBattery() ? "MacBook" : "Mac"
    }

    private static func hardwareIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    private static func hasBattery() -> Bool {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return !sources.isEmpty
    }
}
