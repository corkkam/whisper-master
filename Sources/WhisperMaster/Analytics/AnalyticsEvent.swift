import Foundation

/// Every analytics signal the app can emit, with its wire name and parameters.
///
/// Pure and SDK-agnostic — `Analytics` translates these into PostHog events.
/// **Nothing here carries user content:** only app versions, coarse buckets,
/// and enum-like states. Numbers are bucketed so no single signal is
/// fingerprintable back to a specific session.
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

    /// The PostHog event name (namespaced, dot-separated by convention).
    var name: String {
        switch self {
        case .appLaunched: return "App.launched"
        case .onboardingFinished: return "Onboarding.finished"
        case .dictationCompleted: return "Dictation.completed"
        case .permissionState: return "Permission.state"
        case .updateInstalled: return "Update.installed"
        case .cleanupModelDownloaded: return "Cleanup.modelDownloaded"
        }
    }

    /// Content-free parameters attached to the signal.
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
