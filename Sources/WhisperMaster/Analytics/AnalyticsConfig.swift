import Foundation

/// TelemetryDeck configuration. The app ID comes from the TelemetryDeck
/// dashboard — create an app at https://dashboard.telemetrydeck.com and copy
/// its App ID here.
///
/// Until it's filled in, analytics stays fully dormant (no SDK init, no
/// network), so a missing ID can never leave the SDK half-configured.
enum AnalyticsConfig {
    /// Sentinel meaning "not configured yet".
    static let placeholderAppID = "REPLACE_WITH_TELEMETRYDECK_APP_ID"

    /// The TelemetryDeck App ID. Overridable at runtime via the
    /// `WHISPERMASTER_TELEMETRYDECK_APP_ID` environment variable (handy for
    /// pointing test builds at a throwaway app).
    static let appID: String = {
        if let override = ProcessInfo.processInfo.environment["WHISPERMASTER_TELEMETRYDECK_APP_ID"],
           !override.isEmpty {
            return override
        }
        return "770909F2-630A-4456-9739-18E4A063B6B9"
    }()

    /// Whether a real App ID is present. When false, `Analytics` refuses to
    /// initialize the SDK.
    static var isConfigured: Bool {
        !appID.isEmpty && appID != placeholderAppID
    }
}
