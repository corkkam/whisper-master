import Foundation

/// How setup ended, which `AppDelegate` turns into an `OnboardingFinishPlan`.
/// Closing with × or ⌘W is not a finish; it goes through the model's dismiss.
enum OnboardingFinish: Equatable {
    /// Done on Ready, or the capture key on Ready with the microphone on.
    case handBack
    /// Close and open Settings, offered while the speech files load.
    case openSettings
}

/// What `AppDelegate` does once setup finishes. Every kind also marks the flow
/// seen, dismisses the band and keeps engine prep going.
///
/// Used from PR 4.
struct OnboardingFinishPlan: Equatable {
    var opensSettings: Bool
    /// Give focus back to the app the user came from.
    var handsFocusBack: Bool

    static func plan(for kind: OnboardingFinish, signOutInFlight: Bool) -> OnboardingFinishPlan {
        switch kind {
        case .handBack:
            return OnboardingFinishPlan(opensSettings: false, handsFocusBack: true)
        case .openSettings:
            // A sign-out during the outro lets the completion run, but the gate
            // owns the screen: no Settings window opens behind it.
            return OnboardingFinishPlan(opensSettings: !signOutInFlight, handsFocusBack: false)
        }
    }
}

/// What a dictation key press does while setup is open. It reads the key and
/// the beat, never the words.
enum OnboardingCaptureDecision: Equatable {
    case allow
    /// Ready with the microphone on: cut the band, then record in the same call,
    /// whatever the engine state, so the first word is kept.
    case handOffThenAllow
    case ignore

    static func resolve(onboardingOpen: Bool, step: NotchOnboardingStep, micGranted: Bool) -> OnboardingCaptureDecision {
        guard onboardingOpen else { return .allow }
        guard step == .ready, micGranted else { return .ignore }
        return .handOffThenAllow
    }

    /// Runs a decision and returns whether the caller goes on to record. An
    /// ignored press also resets the key's gesture: without that, a double-tap on
    /// an early beat leaves the gesture latched hands-free, and the next hold on
    /// Ready ends that latch instead of starting. It nudges, except while the mic
    /// check listens, whose own copy already says to hold the key.
    static func apply(
        _ decision: OnboardingCaptureDecision,
        micCheckListening: Bool,
        resetGesture: () -> Void,
        noteSwallowedPress: () -> Void,
        handOff: () -> Void
    ) -> Bool {
        switch decision {
        case .allow:
            return true
        case .handOffThenAllow:
            handOff()
            return true
        case .ignore:
            resetGesture()
            if !micCheckListening { noteSwallowedPress() }
            return false
        }
    }
}

/// When a done step moves on by itself. It waits a floor from the moment its
/// confirmed copy is fully visible: 2.5 s with the pointer over the band, 4.5 s
/// without (someone speaking commands often has the pointer elsewhere). Any
/// cancel is final for the beat, and Continue shows instead.
struct OnboardingAutoAdvance: Equatable {
    static let floor: TimeInterval = 2.5
    static let floorWithoutPointer: TimeInterval = 4.5

    enum Cancel: Equatable {
        /// A key, a pointer move over the band, or a focus change the model did not make.
        case interaction
        /// The app resigned active.
        case appInactive
    }

    var confirmedVisibleAt: TimeInterval?
    /// Read when the confirmed copy becomes fully visible.
    var pointerOverBand: Bool
    var cancel: Cancel?

    /// When the beat advances, or `nil` when it will not.
    var advancesAt: TimeInterval? {
        guard cancel == nil, let confirmedVisibleAt else { return nil }
        return confirmedVisibleAt + (pointerOverBand ? Self.floor : Self.floorWithoutPointer)
    }

    /// The Heard swap only: a voice during the "allowed before" wait restarts it.
    mutating func restart(at time: TimeInterval) {
        confirmedVisibleAt = time
    }
}

/// The Typing beat. macOS posts no "denied" for Accessibility, so "still off"
/// is inferred: asked, then back from System Settings, and still not trusted.
enum TypingStatus: Equatable {
    case ask
    case stillOff
    case granted

    static func resolve(trusted: Bool, asked: Bool, returned: Bool) -> TypingStatus {
        if trusted { return .granted }
        return asked && returned ? .stillOff : .ask
    }
}
