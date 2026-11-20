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
/// seen, dismisses the band and keeps engine prep going (`AppDelegate.endOnboarding`).
struct OnboardingFinishPlan: Equatable {
    var opensSettings: Bool
    /// Give focus back to the app the user came from.
    var handsFocusBack: Bool

    static func plan(for kind: OnboardingFinish, signOutInFlight: Bool) -> OnboardingFinishPlan {
        switch kind {
        case .handBack:
            return OnboardingFinishPlan(opensSettings: false, handsFocusBack: true)
        case .openSettings:
            // A sign-out during the 400 ms outro releases the window, which stops
            // the delayed completion: the flow is not marked seen, and that
            // account sees setup again at the next sign-in. If a completion ever
            // runs while the gate is up, no Settings window opens behind it.
            return OnboardingFinishPlan(opensSettings: !signOutInFlight, handsFocusBack: false)
        }
    }
}

/// What a dictation key press does while setup is open. It reads the key and
/// the beat, never the words.
enum OnboardingCaptureDecision: Equatable {
    case allow
    /// Ready with the microphone on and the engine ready: cut the band, then
    /// record in the same call, so the first word is kept.
    case handOffThenAllow
    case ignore

    /// While the speech files load, the recording would be refused, so a hand-off
    /// would close setup and record nothing: the press is ignored and setup stays.
    static func resolve(
        onboardingOpen: Bool, step: NotchOnboardingStep, micGranted: Bool, engineReady: Bool
    ) -> OnboardingCaptureDecision {
        guard onboardingOpen else { return .allow }
        guard step == .ready, micGranted, engineReady else { return .ignore }
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

/// A key as the band reads it. The panel maps each `keyDown` to one of these.
enum OnboardingKey: Equatable {
    case returnKey
    case escape
    case leftArrow
    /// Space while Full Keyboard Access is off. The model presses the focused button.
    case space
    /// Command W. It closes setup and is exempt from the input gate.
    case closeWindow
    /// Tab, Shift-Tab, and Space under Full Keyboard Access: the focused
    /// controls answer these themselves, after the gate.
    case passThrough
    /// Any other key. It only counts as a key press, which stops a moving-on wait.
    case other
}

/// The band's controls that can hold keyboard focus, in Tab order.
enum OnboardingAction: Equatable, CaseIterable {
    /// The first button of the action row.
    case main
    /// The second button of the action row.
    case second
    case back
    case settings
    case close
}

/// What a key does in one state of the band.
enum OnboardingKeyAction: Equatable {
    case press(OnboardingAction)
    case cancelAutoAdvance
    case nothing
}

/// When keys, clicks and accessibility presses start to count, in system uptime
/// (the clock of `NSEvent.timestamp`). Until then the action row draws at half
/// opacity, so a press cannot land on a button the user has not seen.
enum OnboardingInputGate {
    enum Cause {
        /// T0 of the first-launch opening.
        case opening
        /// A skip of the opening.
        case skip
        /// The band shown at once with no stage: VoiceOver, or no screen for it.
        case reveal
        /// A step change.
        case step
        /// A row change inside a beat.
        case row
    }

    static func opensAt(_ cause: Cause, at time: TimeInterval, policy: OnboardingMotionPolicy) -> TimeInterval {
        let full = policy.layers == .full
        switch cause {
        case .opening:
            return time + (full ? OpeningTimeline.swapAt : OpeningTimeline.stillSwapAt) + BandReveal.inputOpens(policy: policy)
        case .skip:
            return time + (full ? OpeningTimeline.skipBlend : 0) + BandReveal.inputOpens(policy: policy)
        case .reveal:
            return time + BandReveal.inputOpens(policy: policy)
        case .step:
            return time + (full ? BeatTransition.opensAt : BeatTransition.stillOpensAt)
        case .row:
            return time + Flourish.opensAt
        }
    }

    /// A repeat never gets through, nor does a press before input opens. Command W always does.
    static func allows(_ key: OnboardingKey, isRepeat: Bool, at time: TimeInterval, opensAt: TimeInterval) -> Bool {
        if key == .closeWindow { return true }
        return !isRepeat && time >= opensAt
    }
}

/// What Return, Escape, Space and Left Arrow press in one state of the band.
enum OnboardingReturnTarget {
    /// The controls a key may press in this row: its buttons, then Back while
    /// it is enabled, then Settings and Close.
    static func available(row: OnboardingRow, backEnabled: Bool) -> [OnboardingAction] {
        Array([OnboardingAction.main, .second].prefix(row.buttons.count))
            + (backEnabled ? [.back] : []) + [.settings, .close]
    }

    static func resolve(
        _ key: OnboardingKey, row: OnboardingRow, focused: OnboardingAction?, backEnabled: Bool, voiceOver: Bool
    ) -> OnboardingKeyAction {
        if key == .closeWindow { return .press(.close) }
        // A moving-on step: any key stops the wait and presses nothing else.
        if case .badge(_, .movingOn) = row { return .cancelAutoAdvance }
        let available = available(row: row, backEnabled: backEnabled)
        let buttons = row.buttons
        switch key {
        case .returnKey:
            if let focused { return available.contains(focused) ? .press(focused) : .nothing }
            // Under VoiceOver Return with no focus does nothing, so no hint names Return.
            return voiceOver || buttons.isEmpty ? .nothing : .press(.main)
        case .space:
            guard let focused, available.contains(focused) else { return .nothing }
            return .press(focused)
        case .escape:
            if buttons.count == 2 { return .press(.second) }
            // A lone button is pressed only when it is the way past: Not now or Done.
            if buttons == [.notNow] || buttons == [.done] { return .press(.main) }
            return .nothing
        case .leftArrow:
            return backEnabled ? .press(.back) : .nothing
        case .closeWindow, .passThrough, .other:
            return .nothing
        }
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
