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
    /// The signed-in account, held so a sink initialized *after* sign-in still
    /// gets it. Both orders happen for real: analytics can be enabled before Clerk
    /// resolves (launch) or after (a user who opts in from Settings mid-session),
    /// and without this the second case would leave the person profile anonymous
    /// until the next launch.
    private var account: AnalyticsAccount?

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
            // Opting in from Settings *after* signing in: the sinks were built
            // just now, so the account they missed is applied here.
            if let account { applyAccountToSinks(account) }
        } else if didInitializeSDK {
            PostHogSDK.shared.optOut()
        }
        // GA needs no opt-out call: `send` is gated on `isEnabled`, and the
        // client holds nothing to purge — its URLSession is ephemeral (no
        // cookies, no cache) and the only persisted value is the install UUID,
        // which predates GA and is shared with PostHog.
    }

    /// Attach the signed-in Clerk account to everything sent from here on.
    ///
    /// Called when Clerk resolves a session — at launch for a restored one, on
    /// first sign-in otherwise. Idempotent: re-identifying the same account is a
    /// no-op, which matters because the caller is the 0.5s reconcile tick.
    ///
    /// **PostHog's `distinct_id` becomes the Clerk user id**, and `alias` joins the
    /// pre-sign-in install id to it so the events from before the gate (launch,
    /// permission state, onboarding) stay on the same person rather than stranding
    /// a ghost user per install. **GA keeps `client_id` = install id** and gains
    /// `user_id`: GA models those as device and person respectively, and
    /// overwriting `client_id` mid-stream would fork the device's session history.
    func identify(_ account: AnalyticsAccount) {
        guard RegulatedMode.allowsTelemetry else { return }
        guard self.account != account else { return }
        self.account = account

        guard isEnabled else { return }
        applyAccountToSinks(account)
    }

    /// Drop the account on sign-out, so a second user on the same Mac does not
    /// inherit the first one's person profile.
    ///
    /// `reset()` also regenerates PostHog's own anonymous id, so the install id is
    /// re-asserted immediately after — otherwise the next signed-out session would
    /// report under an id that matches neither GA's `client_id` nor anything the
    /// dashboards have seen.
    func resetIdentity() {
        guard account != nil else { return }
        account = nil
        if didInitializeSDK {
            PostHogSDK.shared.reset()
            PostHogSDK.shared.identify(AnalyticsIdentity.installID)
            PostHogSDK.shared.register(Self.superProperties)
        }
        if let google {
            Task { await google.setUserID(nil) }
        }
        Log.analytics.notice("Analytics identity reset (signed out).")
    }

    /// Update the person profile with rolled-up usage — lifetime totals and the
    /// feature posture, not a per-event stream.
    ///
    /// This is what makes "which user is using what" answerable **without** a
    /// query over every event that person ever sent: PostHog can cohort and filter
    /// on a person property directly, where a per-user feature tally otherwise
    /// means an aggregation across the full event history. Person-scoped only —
    /// GA4 has no equivalent that the Measurement Protocol can write.
    func updatePersonProperties(_ properties: [String: String]) {
        guard RegulatedMode.allowsTelemetry, isEnabled, didInitializeSDK else { return }
        guard !properties.isEmpty else { return }
        PostHogSDK.shared.capture("$set", properties: ["$set": properties])
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

        // Native crash capture — PLCrashReporter, vendored inside this SDK, so
        // this costs no new dependency and no new vendor.
        //
        // It installs Mach exception, POSIX signal, and uncaught-`NSException`
        // handlers, which is what it takes to see the crashes this app actually
        // has: an Objective-C exception out of `AVAudioEngine` is an `abort()`,
        // and the field crash on stable 1.0.1 was an `EXC_BAD_ACCESS` inside the
        // Metal driver with MLX frames below it. Both kill the process somewhere
        // no Swift `catch` and no `NSSetUncaughtExceptionHandler` can reach.
        // Crashes are written to disk and sent as `$exception` on the next
        // launch, carrying the `channel` super property registered below — which
        // is what makes beta and stable crash rates separable.
        //
        // **This does not replace `CrashReporter`.** That reads the OS's own
        // `.ips` and feeds the GA counter that sits beside the acquisition
        // funnel; this one carries the stack for debugging. Different questions.
        //
        // Two things about the lifecycle are load-bearing and easy to get wrong:
        // the handlers install during `setup`, which only ever runs from here —
        // i.e. never for a user who has analytics off — and `optOut()`
        // *uninstalls* them (`optIn()` reinstalls), so the Settings toggle tears
        // the handler down rather than merely muting it.
        config.errorTrackingConfig.autoCapture = true
        // Mark our own frames in-app so a stack opens on our code rather than on
        // the driver frame at the top. `PRODUCT_NAME` is `WhisperMaster`, and the
        // prefix also catches the debug build's `WhisperMaster.debug.dylib`.
        // The SDK infers this from the bundle id and executable name anyway; it's
        // stated explicitly because the app is *renamed* per channel ("Whisper
        // Master Beta.app"), and a wrong inference here is invisible until a
        // stack arrives unhelpfully grouped.
        config.errorTrackingConfig.inAppIncludes = ["WhisperMaster"]

        PostHogSDK.shared.setup(config)
        // Which build this is, on every event *and* on the person.
        //
        // Both are needed and they answer different questions. The super
        // property splits **events** by channel ("crashes on beta this week");
        // the person property splits **users** ("how many people are on beta"),
        // which an event property cannot do — PostHog's unique-user and
        // retention maths runs off the person profile, so a channel that only
        // exists on events can't be a cohort. `register` must follow `setup`:
        // it no-ops while the SDK is unconfigured.
        //
        // `appVersion` rides along for the same reason and with the same split:
        // the SDK's own `$app_version` is attached to events, so "crashes on
        // 1.1.0-beta.1" already works, but a *person* cannot be cohorted by it.
        // Registering it here means "everyone still on 1.0.1" is a cohort, and
        // channel × version together are what separate a beta tester's numbers
        // from a stable user's on the same build lineage.
        PostHogSDK.shared.register(Self.superProperties)
        // Pre-sign-in identity. Replaced by the Clerk user id the moment
        // `identify(_:)` is called — see `AnalyticsAccount`.
        PostHogSDK.shared.identify(
            AnalyticsIdentity.installID,
            userProperties: Self.superProperties
        )
        didInitializeSDK = true
        Log.analytics.notice("Analytics enabled (PostHog initialized).")
    }

    /// Attached to every event *and* every person profile.
    ///
    /// Kept in one place so the event stream and the person profile can never
    /// disagree about which build produced a signal.
    private static var superProperties: [String: String] {
        [
            "channel": ReleaseChannel.current.rawValue,
            "appVersion": AnalyticsIdentity.currentVersion,
        ]
    }

    /// Push an account onto whichever sinks are live. Split out because it runs
    /// from two orders — identify-then-enable and enable-then-identify.
    private func applyAccountToSinks(_ account: AnalyticsAccount) {
        if didInitializeSDK {
            PostHogSDK.shared.identify(account.id, userProperties: account.personProperties)
            // Join the pre-sign-in install id to this person. Without it the
            // launch/permission/onboarding events that fired before the gate stay
            // on a separate anonymous user and the activation funnel breaks at
            // exactly the step it exists to measure.
            PostHogSDK.shared.alias(AnalyticsIdentity.installID)
        }
        if let google {
            let id = account.id
            Task { await google.setUserID(id) }
        }
        Log.analytics.notice("Analytics identity set to the signed-in account.")
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
