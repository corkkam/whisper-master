import Foundation

/// PostHog configuration. The project API key comes from the PostHog project
/// (Project settings → "Project API Key", starts `phc_`); the host is the
/// region's ingestion endpoint (US or EU cloud, or a self-hosted URL).
///
/// Until the key is filled in, analytics stays fully dormant (no SDK init, no
/// network), so a missing key can never leave the SDK half-configured.
enum AnalyticsConfig {
    /// Sentinel meaning "not configured yet".
    static let placeholderKey = "REPLACE_WITH_POSTHOG_API_KEY"

    /// The PostHog project API key. Kept out of source: resolved at runtime from
    ///   1. the `WHISPERMASTER_POSTHOG_API_KEY` env var (dev / `swift build`), else
    ///   2. the `POSTHOGAPIKey` Info.plist entry, which xcodebuild substitutes at
    ///      build time from the `POSTHOG_API_KEY` build setting fed by `.env`
    ///      (`bundle.sh`) / a CI secret,
    /// else the placeholder — in which case analytics stays dormant. PostHog
    /// project keys are publishable (they ship in every client), so this is about
    /// not committing it, not secrecy.
    static let apiKey: String = {
        if let override = ProcessInfo.processInfo.environment["WHISPERMASTER_POSTHOG_API_KEY"],
           !override.isEmpty {
            return override
        }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "POSTHOGAPIKey") as? String,
           !baked.isEmpty, baked != placeholderKey, !baked.hasPrefix("$(") {
            return baked
        }
        return placeholderKey
    }()

    /// The PostHog ingestion host. US cloud by default; override with
    /// `WHISPERMASTER_POSTHOG_HOST` for EU (`https://eu.i.posthog.com`) or a
    /// self-hosted instance.
    static let host: String = {
        if let override = ProcessInfo.processInfo.environment["WHISPERMASTER_POSTHOG_HOST"],
           !override.isEmpty {
            return override
        }
        return "https://us.i.posthog.com"
    }()

    /// Whether a real API key is present. When false, `Analytics` refuses to
    /// initialize the SDK.
    static var isConfigured: Bool {
        !apiKey.isEmpty && apiKey != placeholderKey
    }
}
