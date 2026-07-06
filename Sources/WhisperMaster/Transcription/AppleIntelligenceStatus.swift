import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// App-facing availability of Apple's on-device model, mapped from
/// `SystemLanguageModel.availability`. Drives both gating and the Settings hint.
enum AppleIntelligenceStatus: Sendable, Equatable {
    /// Model is ready — formatting will run.
    case available
    /// Apple Intelligence is off in System Settings (user must enable it).
    case notEnabled
    /// Enabled but the model is still downloading / warming up.
    case modelNotReady
    /// This Mac can't run Apple Intelligence.
    case notSupported
    /// Running on macOS older than 26 (no FoundationModels).
    case unsupportedOS

    /// Query the current status. Cheap and safe to call from any thread.
    static var current: AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return .notEnabled
                case .deviceNotEligible: return .notSupported
                case .modelNotReady: return .modelNotReady
                @unknown default: return .modelNotReady
                }
            }
        }
        #endif
        return .unsupportedOS
    }

    var isReady: Bool { self == .available }

    /// One-line explanation shown under the Settings toggle when not ready.
    var settingsHint: String? {
        switch self {
        case .available:
            return nil
        case .notEnabled:
            return "Turn on Apple Intelligence in System Settings to format numbers and symbols."
        case .modelNotReady:
            return "Apple Intelligence is getting ready (the model is downloading). Formatting starts working once it finishes."
        case .notSupported:
            return "This Mac doesn't support Apple Intelligence, so on-device formatting isn't available."
        case .unsupportedOS:
            return "On-device formatting needs macOS 26 or later."
        }
    }

    /// Whether an "Open System Settings" button makes sense for this state.
    var canOpenSettings: Bool {
        self == .notEnabled || self == .modelNotReady
    }
}
