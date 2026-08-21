import Foundation

/// App metadata read from the bundle, so UI never hardcodes values that drift
/// from `Info.plist` (e.g. the version, which Sparkle updates change).
enum AppInfo {
    /// Marketing version, e.g. "0.1.1" (CFBundleShortVersionString).
    static let version: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }()

    /// The channel this **binary** was built for, read from its bundle id (the
    /// ids `Scripts/channel.sh` assigns).
    ///
    /// ⚠️ Deliberately **not** `BetaAccess.currentChannel`. That resolves which
    /// *feed* to poll and promotes a stable build to `.beta` for any user
    /// carrying the `betaAccess` flag — correct for updates, wrong for a badge.
    /// A label beside the version names the build in the user's hands, so it
    /// keys off the bundle id alone; routing it through the flag would relabel
    /// an unchanged binary the moment someone flipped a server-side setting.
    static let buildChannel: UpdateChannel = {
        switch Bundle.main.bundleIdentifier {
        case "app.whispermaster.mac.beta": return .beta
        case "app.whispermaster.mac.dev": return .dev
        default: return .stable
        }
    }()
}
