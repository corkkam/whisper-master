import Foundation

/// App metadata read from the bundle, so UI never hardcodes values that drift
/// from `Info.plist` (e.g. the version, which Sparkle updates change).
enum AppInfo {
    /// Marketing version, e.g. "0.1.1" (CFBundleShortVersionString).
    static let version: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }()

    /// The channel this **binary** was built for, derived from `ReleaseChannel`
    /// so the badge and the feature gate can never disagree about what is running.
    ///
    /// ⚠️ Deliberately **not** `BetaAccess.allowedChannels`. That says which
    /// items this *user* may receive — correct for updates, wrong for a badge. A
    /// label beside the version names the build in the user's hands, so it reads
    /// the running binary alone; routing it through the flag would relabel an
    /// unchanged binary the moment someone flipped a server-side setting.
    static let buildChannel: UpdateChannel = {
        switch ReleaseChannel.current {
        case .stable: return .stable
        case .beta: return .beta
        case .dev: return .dev
        }
    }()
}
