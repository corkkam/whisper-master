import Foundation

/// Credentials for both analytics sinks — PostHog and Google Analytics 4.
///
/// PostHog's project API key comes from the PostHog project (Project settings →
/// "Project API Key", starts `phc_`); the host is the region's ingestion
/// endpoint (US or EU cloud, or a self-hosted URL). GA4's pair comes from the
/// data stream (see `googleMeasurementID` / `googleAPISecret`).
///
/// **Each sink is gated independently and both are dormant until configured** —
/// no SDK init, no network — so a build with only one of them set sends only to
/// that one, and a build with neither is analytics-silent.
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

    // MARK: - Google Analytics 4

    /// The GA4 **measurement ID** (`G-XXXXXXXXXX`), from Admin → Data streams →
    /// the stream → "Measurement ID".
    ///
    /// ⚠️ Create a **Web** data stream, not an iOS/Android one. Only web streams
    /// have a `G-…` measurement ID; app streams are Firebase-backed and identify
    /// themselves with `firebase_app_id` + `app_instance_id`, which is a
    /// different Measurement Protocol payload than the one `GA4Payload` sends —
    /// and getting a Firebase app id would mean adopting Firebase, which is the
    /// dependency this whole approach exists to avoid. A "web" stream fed by a
    /// native client is unusual but fully supported; it's how GA models any
    /// non-Firebase sender.
    ///
    /// Resolved like the PostHog key: `WHISPERMASTER_GA_MEASUREMENT_ID` env var
    /// (dev / `swift build`, which has no bundle Info.plist) else the
    /// `GAMeasurementID` Info.plist entry that xcodebuild substitutes from the
    /// `GA_MEASUREMENT_ID` build setting fed by `.env` / a CI secret.
    ///
    /// Use a **data stream of its own** for the app rather than the landing
    /// page's (`NEXT_PUBLIC_GA_MEASUREMENT_ID`) — same property is fine and lets
    /// you see site→app together, but sharing one stream blends desktop sessions
    /// into web sessions and makes both sets of numbers hard to read.
    static let googleMeasurementID: String = resolve(
        environmentKey: "WHISPERMASTER_GA_MEASUREMENT_ID",
        infoPlistKey: "GAMeasurementID"
    )

    /// The GA4 **Measurement Protocol API secret**, from that same data stream →
    /// "Measurement Protocol API secrets" → Create.
    ///
    /// ⚠️ Unlike the PostHog project key, this one is *not* designed to be
    /// publishable — it ships inside the bundle and anyone can extract it from a
    /// downloaded `.app`. The exposure is bounded (it can only be used to *write*
    /// events into this GA property, never to read anything or reach any other
    /// Google service), but a leaked secret means someone could pollute the
    /// property with junk events. If that ever happens, revoke the secret in the
    /// GA UI and ship a new one — which is also why this is a build-time value
    /// rather than a hardcoded literal. Keep it in a **separate, disposable**
    /// data stream so a revoke never touches the website's analytics.
    static let googleAPISecret: String = resolve(
        environmentKey: "WHISPERMASTER_GA_API_SECRET",
        infoPlistKey: "GAAPISecret"
    )

    /// Whether both halves of the GA4 pair look real. The measurement-ID shape is
    /// checked (same `^G-[A-Z0-9]+$` test the landing page uses in
    /// `lib/analytics.ts`) because a half-substituted build setting yields a
    /// non-empty string like `$(GA_MEASUREMENT_ID)` that GA would accept and
    /// silently drop every event for.
    static var isGoogleConfigured: Bool {
        guard !googleAPISecret.isEmpty else { return false }
        return googleMeasurementID.range(
            of: "^G-[A-Z0-9]+$",
            options: [.regularExpression]
        ) != nil
    }

    /// Route GA hits to the validation endpoint instead of production.
    ///
    /// Production answers `204` for a malformed payload, so a mistake is
    /// invisible; `WHISPERMASTER_GA_DEBUG=1` posts to `/debug/mp/collect`, which
    /// answers with the actual `validationMessages`, logged under the `analytics`
    /// category. Nothing recorded this way reaches the reports — it's for
    /// verifying a new event's shape, not for gathering data.
    static var useGoogleDebugEndpoint: Bool {
        ProcessInfo.processInfo.environment["WHISPERMASTER_GA_DEBUG"] == "1"
    }

    /// Context params merged into every GA4 event.
    ///
    /// A browser tag would get all of this from the User-Agent and GA's own
    /// enrichment; a native app sends nothing GA recognises, so app version and
    /// OS version have to travel as explicit params. Register them under
    /// Admin → Custom definitions → Custom dimensions (event-scoped) or they
    /// stay invisible outside a single event's detail view. Geo/country still
    /// comes from the request IP, so it needs nothing here.
    static var googleBaseParameters: [String: String] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "app_version": AnalyticsIdentity.currentVersion,
            "os_version": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "platform": "macos",
        ]
    }

    // MARK: - Resolution

    /// Env var (dev / `swift build`) → Info.plist (xcodebuild substitution) → "".
    ///
    /// An unsubstituted `$(…)` means the build setting was never passed, which is
    /// the "not configured" case, not a value.
    private static func resolve(environmentKey: String, infoPlistKey: String) -> String {
        if let override = ProcessInfo.processInfo.environment[environmentKey], !override.isEmpty {
            return override
        }
        if let baked = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
           !baked.isEmpty, !baked.hasPrefix("$(") {
            return baked
        }
        return ""
    }
}
