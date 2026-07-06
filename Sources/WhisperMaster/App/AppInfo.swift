import Foundation

/// App metadata read from the bundle, so UI never hardcodes values that drift
/// from `Info.plist` (e.g. the version, which Sparkle updates change).
enum AppInfo {
    /// Marketing version, e.g. "0.1.1" (CFBundleShortVersionString).
    static let version: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }()
}
