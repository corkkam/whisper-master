import Foundation
import PostHog

/// The single seam between Whisper Master and PostHog.
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
    /// first time and opts in; disabling opts out so no further events leave.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            initializeSDKIfNeeded()
            if didInitializeSDK { PostHogSDK.shared.optIn() }
        } else if didInitializeSDK {
            PostHogSDK.shared.optOut()
        }
    }

    /// Emit an event. No-op unless the user has opted in and the SDK is live.
    func send(_ event: AnalyticsEvent) {
        guard isEnabled, didInitializeSDK else { return }
        PostHogSDK.shared.capture(event.name, properties: event.parameters)
    }

    private func initializeSDKIfNeeded() {
        guard !didInitializeSDK else { return }
        guard AnalyticsConfig.isConfigured else {
            Log.analytics.error(
                "PostHog API key not set — analytics stays off. Fill in AnalyticsConfig.apiKey."
            )
            return
        }
        let config = PostHogConfig(apiKey: AnalyticsConfig.apiKey, host: AnalyticsConfig.host)
        // Menu-bar app: no UIKit screens or lifecycle to autocapture, so keep the
        // stream to just our explicit, content-free events.
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        PostHogSDK.shared.setup(config)
        // Use our own anonymous, stable identifier as the distinct id so
        // unique-user / retention counts work without anything identifying
        // (a random UUID, same role as before).
        PostHogSDK.shared.identify(AnalyticsIdentity.installID)
        didInitializeSDK = true
        Log.analytics.notice("Analytics enabled (PostHog initialized).")
    }
}
