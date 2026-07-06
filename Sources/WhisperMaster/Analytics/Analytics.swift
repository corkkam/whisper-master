import Foundation
import TelemetryDeck

/// The single seam between Whisper Master and TelemetryDeck.
///
/// Nothing else in the app imports the analytics SDK, so swapping vendors (or
/// moving to self-hosted / a DIY endpoint) is a change to this one file. All
/// sending is gated on the user's opt-in: when disabled, every call is a no-op
/// and no network traffic occurs. The SDK is initialized lazily the first time
/// analytics is enabled, never before.
@MainActor
final class Analytics {
    static let shared = Analytics()

    private var isEnabled = false
    private var didInitializeSDK = false

    private init() {}

    /// Called once at launch with the persisted opt-in. Safe to call before the
    /// user has decided — it only spins up the SDK when enabled.
    func configure(enabled: Bool) {
        setEnabled(enabled)
    }

    /// React to the Settings toggle. Enabling lazily initializes the SDK the
    /// first time; disabling stops all further signals.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard enabled else { return }
        initializeSDKIfNeeded()
    }

    /// Emit an event. No-op unless the user has opted in and the SDK is live.
    func send(_ event: AnalyticsEvent) {
        guard isEnabled, didInitializeSDK else { return }
        TelemetryDeck.signal(event.name, parameters: event.parameters)
    }

    private func initializeSDKIfNeeded() {
        guard !didInitializeSDK else { return }
        guard AnalyticsConfig.isConfigured else {
            Log.analytics.error(
                "TelemetryDeck App ID not set — analytics stays off. Fill in AnalyticsConfig.appID."
            )
            return
        }
        let config = TelemetryDeck.Config(appID: AnalyticsConfig.appID)
        TelemetryDeck.initialize(config: config)
        // Supply our own anonymous, stable identifier; TelemetryDeck hashes it
        // on-device so unique-user / retention counts stay non-identifying.
        TelemetryDeck.updateDefaultUserID(to: AnalyticsIdentity.installID)
        didInitializeSDK = true
        Log.analytics.notice("Analytics enabled (TelemetryDeck initialized).")
    }
}
