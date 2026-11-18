import Foundation

// Onboarding motion as pure functions of elapsed time, so the headless snapshot
// renderer can draw any instant and tests can pin every curve. The orb's figure
// changes by a dip, the orb's gain follows only a voice that was really heard,
// and a live grant raises one bloom that holds still. Every layer plays once and
// then holds; only the orb keeps moving.

/// How much of onboarding moves, read from the system once when the band shows
/// and again on the window's poll.
struct OnboardingMotionPolicy: Equatable {
    enum Layers: Equatable {
        /// Every layer plays.
        case full
        /// Copy and beads change in place, figures change with no dip, and no
        /// bloom rises.
        case still
    }

    var layers: Layers
    /// VoiceOver only: the opening stage is never shown or spoken.
    var skipsStage: Bool
    /// System Reduce Motion only: the orb draws its one static frame.
    var orbIsStatic: Bool

    static func resolve(
        reduceMotion: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState, voiceOver: Bool
    ) -> OnboardingMotionPolicy {
        let hot = thermal == .serious || thermal == .critical
        let still = reduceMotion || lowPower || hot || voiceOver
        return OnboardingMotionPolicy(
            layers: still ? .still : .full, skipsStage: voiceOver, orbIsStatic: reduceMotion)
    }
}

/// An orb figure is the `OrbView.Mode`; the preset never changes and the gain
/// is a live input, not a figure.
typealias OrbFigure = OrbView.Mode

extension OrbView.Mode {
    /// The opening stage's figure, which the band orb also draws at the swap.
    static let stage: OrbView.Mode = .listening

    /// The orb's figure for a beat. Microphone: working while the system prompt
    /// is up, thinking when the mic check failed, listening once the mic is on,
    /// thinking otherwise. Typing and Start with your Mac: listening when
    /// granted, thinking otherwise. Ready: listening.
    static func resolve(
        step: NotchOnboardingStep, requestingMic: Bool, granted: Bool, micCheckFailed: Bool
    ) -> OrbView.Mode {
        switch step {
        case .microphone:
            if requestingMic { return .working }
            if micCheckFailed { return .thinking }
            return granted ? .listening : .thinking
        case .accessibility, .openAtLogin:
            return granted ? .listening : .thinking
        case .ready:
            return .listening
        }
    }
}

/// The one way the orb changes figure: down to 0.35 opacity and 0.90 scale over
/// 140 ms on `fade`, the figure swaps at the low point, then back to 1 over
/// 280 ms on `settle`. It plays on every figure change and never when the figure
/// stays the same.
enum OrbDip {
    struct Frame: Equatable {
        var opacity: Double
        var scale: Double
        /// False until the low point, when the new figure takes over.
        var figureIsNew: Bool
    }

    static let rest = Frame(opacity: 1, scale: 1, figureIsNew: true)
    static let low: TimeInterval = 0.14
    static let duration: TimeInterval = 0.42
    static let lowOpacity = 0.35
    static let lowScale = 0.90

    /// Whether a change from `old` to `new` dips at all.
    static func plays(from old: OrbView.Mode, to new: OrbView.Mode) -> Bool { old != new }

    /// The dip `elapsed` seconds after it started from `start` (the rest frame,
    /// or wherever a running dip was when a new one began).
    static func frame(at elapsed: TimeInterval, from start: Frame = rest, policy: OnboardingMotionPolicy) -> Frame {
        guard policy.layers == .full else { return rest }
        if elapsed < low {
            let p = CubicBezier.fade.value(at: max(0, elapsed) / low)
            return Frame(
                opacity: start.opacity + (lowOpacity - start.opacity) * p,
                scale: start.scale + (lowScale - start.scale) * p,
                figureIsNew: false)
        }
        let p = CubicBezier.settle.value(at: (elapsed - low) / (duration - low))
        return Frame(
            opacity: lowOpacity + (1 - lowOpacity) * p,
            scale: lowScale + (1 - lowScale) * p,
            figureIsNew: true)
    }

    /// A second figure change while a dip runs. Before the low point the running
    /// dip only takes the newest figure as its target (false); from the low
    /// point on, a new dip starts from the current frame (true).
    static func restarts(changeAt elapsed: TimeInterval) -> Bool { elapsed >= low }
}

/// The orb's listening gain during onboarding. Never scripted: 0 whenever the
/// mic check is not running and 0 until a voice is heard, so no state shows a
/// wave the user did not make. After the latch, `OrbView`'s 0.35 floor comes in
/// over 280 ms on `settle`, and the level adds `OrbView`'s 1.05 × activity.
enum OnboardingOrbGain {
    static let floor = 0.35
    static let floorRise: TimeInterval = 0.28

    static func resolve(micCheckRunning: Bool, heardAt: TimeInterval?, now: TimeInterval, level: Float) -> Double {
        guard micCheckRunning, let heardAt, now >= heardAt else { return 0 }
        let rise = CubicBezier.settle.value(at: (now - heardAt) / floorRise)
        return floor * rise + 1.05 * OrbView.waveActivity(level)
    }
}

/// The soft glow a live grant raises behind the orb. It rises once, from the
/// dip's low point to `Theme.Notch.bloomAlpha` over 420 ms on `settle`, then
/// holds still until the beat changes. It never pulses.
enum OnboardingBloom {
    /// Hue meanings are load-bearing: ember is your voice, signal is the machine.
    enum Hue: Equatable {
        /// Ember, only when the app really heard your voice.
        case voice
        /// Signal: the Typing and Start-with-your-Mac grants.
        case machine
    }

    static let startsAt: TimeInterval = 0.14
    static let duration: TimeInterval = 0.42

    /// `liveGrant` is false for a grant the user comes back to (after Back), which
    /// draws no bloom. The still policy (Reduce Motion, VoiceOver and the rest)
    /// draws none either.
    static func alpha(at elapsed: TimeInterval, liveGrant: Bool, policy: OnboardingMotionPolicy) -> Double {
        guard liveGrant, policy.layers == .full, elapsed >= startsAt else { return 0 }
        return Theme.Notch.bloomAlpha * CubicBezier.settle.value(at: (elapsed - startsAt) / duration)
    }

    /// Which bloom a beat's grant raises, if any. A microphone grant alone raises
    /// none: only a heard voice does.
    static func hue(for step: NotchOnboardingStep, heardVoice: Bool) -> Hue? {
        switch step {
        case .microphone: return heardVoice ? .voice : nil
        case .accessibility, .openAtLogin: return .machine
        case .ready: return nil
        }
    }
}
