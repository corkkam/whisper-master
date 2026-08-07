import Foundation

/// Every analytics signal the app can emit, with its wire names and parameters.
///
/// Pure and SDK-agnostic — `Analytics` translates these into PostHog events and
/// Google Analytics 4 events. **Nothing here carries user content:** only app
/// versions, coarse buckets, and enum-like states. Numbers are bucketed so no
/// single signal is fingerprintable back to a specific session.
///
/// The two vendors get **different spellings of the same event** (`name` vs
/// `googleName`) because GA4 rejects anything outside
/// `[A-Za-z][A-Za-z0-9_]{0,39}` — no dots — while PostHog's existing dotted
/// names are already live in dashboards and must not be renamed under them.
enum AnalyticsEvent {
    /// The app was launched. Drives DAU/WAU/MAU, retention, and (via the SDK's
    /// automatic metadata) version / macOS / device / country breakdowns.
    case appLaunched
    /// The setup wizard was completed — the activation rate for new installs.
    case onboardingFinished
    /// A dictation session finished with non-empty text.
    case dictationCompleted(engine: String, duration: TimeInterval, wordCount: Int)
    /// The current permission posture, sampled at launch.
    case permissionState(accessibility: Bool, microphone: Bool)
    /// First launch on a newer app version — how fast Sparkle rollouts land.
    case updateInstalled(from: String, to: String)
    /// The optional on-device Smart cleanup (LLM) model finished downloading and
    /// loaded for the first time — i.e. a user actually pulled the ~1.5 GB model.
    /// This is the "how many adopted the LLM" counter.
    case cleanupModelDownloaded
    /// The previous run ended without reaching `applicationWillTerminate`,
    /// reported on the next launch by `CrashReporter`. A `nil` report means the
    /// exit was unclean but no matching `.ips` was readable — see `hasReport`.
    case appCrashed(CrashReport?)

    /// The PostHog event name (namespaced, dot-separated by convention).
    var name: String {
        switch self {
        case .appLaunched: return "App.launched"
        case .onboardingFinished: return "Onboarding.finished"
        case .dictationCompleted: return "Dictation.completed"
        case .permissionState: return "Permission.state"
        case .updateInstalled: return "Update.installed"
        case .cleanupModelDownloaded: return "Cleanup.modelDownloaded"
        case .appCrashed: return "App.crashed"
        }
    }

    /// The GA4 event name — snake_case, and deliberately **not** derived from
    /// `name` by string munging, since these strings are what analysts will read
    /// in the GA reports and a rename there orphans a saved exploration.
    ///
    /// None collide with GA's reserved names (`first_open`, `session_start`,
    /// `user_engagement`, `in_app_purchase`, `app_remove`, …) or its reserved
    /// prefixes (`ga_`, `google_`, `firebase_`), which GA drops on sight.
    var googleName: String {
        switch self {
        case .appLaunched: return "app_launched"
        case .onboardingFinished: return "onboarding_finished"
        case .dictationCompleted: return "dictation_completed"
        case .permissionState: return "permission_state"
        case .updateInstalled: return "update_installed"
        case .cleanupModelDownloaded: return "cleanup_model_downloaded"
        case .appCrashed: return "app_crashed"
        }
    }

    /// Content-free parameters attached to the signal.
    ///
    /// **One catalog for both sinks.** PostHog gets these names verbatim (they're
    /// already live in its dashboards); GA gets them converted to its snake_case
    /// convention by `GA4Limits.parameterName`, so `wordCountBucket` is registered
    /// as the custom dimension `word_count_bucket`. Doing that as a deterministic
    /// transform rather than a second hand-written dictionary is what keeps the
    /// two vendors from drifting apart.
    var parameters: [String: String] {
        switch self {
        case .appLaunched, .onboardingFinished, .cleanupModelDownloaded:
            return [:]
        case let .dictationCompleted(engine, duration, wordCount):
            return [
                "engine": engine,
                "durationBucket": Self.durationBucket(duration),
                "wordCountBucket": Self.wordCountBucket(wordCount),
            ]
        case let .permissionState(accessibility, microphone):
            return [
                "accessibility": accessibility ? "granted" : "denied",
                "microphone": microphone ? "granted" : "denied",
            ]
        case let .updateInstalled(from, to):
            return ["fromVersion": from, "toVersion": to]
        case let .appCrashed(report):
            // `hasReport` is the honesty flag. An unclean exit is also what a
            // Force Quit, a kernel panic, and a power cut look like, so the two
            // cases must stay separable in the reports: `hasReport=true` is a
            // confirmed crash with a stack, `false` is "ended abruptly, cause
            // unknown". Collapsing them would inflate the crash rate with every
            // user who ever force-quit the app.
            guard let report else {
                return [
                    "hasReport": "false",
                    "exceptionType": "unknown",
                    "crashSignature": "unknown",
                ]
            }
            return [
                "hasReport": "true",
                "exceptionType": report.exceptionType,
                "crashSignal": report.signal,
                "crashSignature": report.signature,
                "crashBinary": report.binary,
                // The version that *crashed*, which is not necessarily the one
                // reporting it — the report is read on the next launch, which may
                // already be a Sparkle update later.
                "crashedVersion": report.crashedVersion,
            ]
        }
    }

    /// Coarse session-length bucket — never the exact duration.
    static func durationBucket(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<5: return "0-5s"
        case ..<15: return "5-15s"
        case ..<30: return "15-30s"
        case ..<60: return "30-60s"
        case ..<180: return "1-3m"
        default: return "3m+"
        }
    }

    /// Coarse transcript-length bucket — never the exact word count or text.
    static func wordCountBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "0"
        case ..<10: return "1-9"
        case ..<25: return "10-24"
        case ..<50: return "25-49"
        case ..<100: return "50-99"
        case ..<250: return "100-249"
        default: return "250+"
        }
    }
}
