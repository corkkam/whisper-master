import Foundation
import PostHog

/// The single seam between Whisper Master and every analytics vendor.
///
/// Nothing else in the app imports an analytics SDK or builds a request, so
/// adding, swapping, or dropping a vendor is a change to this one file. Today it
/// fans each `AnalyticsEvent` out to two sinks:
///
/// - **PostHog** — product analytics: funnels, retention, per-user event streams.
/// - **Google Analytics 4** — the same events in the same property as the
///   landing page (`whisper-master-landing-page/lib/analytics.ts`), which is the
///   point: GA is where site visits, downloads, and now app usage can be read as
///   one acquisition→activation story instead of two disconnected dashboards.
///   It goes over the Measurement Protocol, so it adds **no dependency** — see
///   `GoogleAnalyticsClient` for why not Firebase.
///
/// Each sink is independently gated on its own credentials and both are gated on
/// the user's opt-in: when disabled, every call is a no-op and no network
/// traffic occurs. Neither is initialized before analytics is first enabled.
///
/// Running both is deliberate but not permanent — if GA proves sufficient,
/// deleting the PostHog half is a matter of dropping `initializeSDKIfNeeded`,
/// the `PostHogSDK` calls below, and the package from `project.yml`/`Package.swift`.
@MainActor
final class Analytics {
    static let shared = Analytics()

    private var isEnabled = false
    private var didInitializeSDK = false
    /// Built on first enable, when GA credentials are present. `nil` means GA is
    /// unconfigured for this build and every GA send is skipped.
    private var google: GoogleAnalyticsClient?

    private init() {}

    /// Called once at launch with the persisted opt-in. Safe to call before the
    /// user has decided — it only spins up the sinks when enabled.
    func configure(enabled: Bool) {
        setEnabled(enabled)
    }

    /// React to the Settings toggle. Enabling lazily initializes each configured
    /// sink the first time and opts in; disabling opts out so no further events
    /// leave.
    func setEnabled(_ enabled: Bool) {
        // Regulated Mode overrides the preference outright. Checked here rather
        // than only where the toggle is drawn, because this method is also
        // reached from `configure(enabled:)` at launch with a persisted value —
        // a Mac that had analytics on before the profile was installed must not
        // send anything on the next launch.
        guard RegulatedMode.allowsTelemetry else {
            isEnabled = false
            if didInitializeSDK { PostHogSDK.shared.optOut() }
            Log.analytics.notice("Regulated Mode active — analytics disabled by policy.")
            return
        }
        isEnabled = enabled
        if enabled {
            initializeSDKIfNeeded()
            initializeGoogleIfNeeded()
            if didInitializeSDK { PostHogSDK.shared.optIn() }
        } else if didInitializeSDK {
            PostHogSDK.shared.optOut()
        }
        // GA needs no opt-out call: `send` is gated on `isEnabled`, and the
        // client holds nothing to purge — its URLSession is ephemeral (no
        // cookies, no cache) and the only persisted value is the install UUID,
        // which predates GA and is shared with PostHog.
    }

    /// Emit an event to every enabled, configured sink. No-op unless the user has
    /// opted in.
    func send(_ event: AnalyticsEvent) {
        // Belt and braces with `setEnabled`. This is the last statement before
        // bytes reach either sink, so it is the one place where a missed gate
        // upstream — a future code path that sets `isEnabled` directly, a
        // profile installed mid-session — still cannot produce a transmission.
        guard RegulatedMode.allowsTelemetry else { return }
        guard isEnabled else { return }

        if didInitializeSDK {
            PostHogSDK.shared.capture(event.name, properties: event.parameters)
        }

        if let google {
            // Detached from the caller: an analytics hit must never sit in the
            // path of a dictation finishing. Failures are logged and dropped
            // inside the client.
            let name = event.googleName
            let parameters = event.parameters
            Task { await google.send(name: name, parameters: parameters) }
        }
    }

    private func initializeSDKIfNeeded() {
        guard !didInitializeSDK else { return }
        guard AnalyticsConfig.isConfigured else {
            Log.analytics.error(
                "PostHog API key not set — PostHog stays off. Fill in AnalyticsConfig.apiKey."
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

    private func initializeGoogleIfNeeded() {
        guard google == nil else { return }
        guard AnalyticsConfig.isGoogleConfigured else {
            Log.analytics.notice(
                "GA4 measurement ID / API secret not set — Google Analytics stays off."
            )
            return
        }
        google = GoogleAnalyticsClient(
            measurementID: AnalyticsConfig.googleMeasurementID,
            apiSecret: AnalyticsConfig.googleAPISecret,
            // Same anonymous install UUID as PostHog's distinct id, so the same
            // person is one user in both tools and neither gets anything more
            // identifying than the other.
            clientID: AnalyticsIdentity.installID,
            baseParameters: AnalyticsConfig.googleBaseParameters,
            useDebugEndpoint: AnalyticsConfig.useGoogleDebugEndpoint
        )
        Log.analytics.notice("Analytics enabled (GA4 Measurement Protocol ready).")
    }
}
