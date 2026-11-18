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

// MARK: - Clock and frames

/// The time every onboarding frame is drawn at, in system uptime: the clock of
/// `NSEvent.timestamp`. The snapshot renderer pins it to one instant.
struct OnboardingClock {
    let now: () -> TimeInterval
    /// A fixed clock never animates, so the band's timeline stays paused.
    let isFixed: Bool

    static let live = OnboardingClock(now: { ProcessInfo.processInfo.systemUptime }, isFixed: false)

    static func fixed(_ time: TimeInterval) -> OnboardingClock {
        OnboardingClock(now: { time }, isFixed: true)
    }
}

/// One layer of a frame: its opacity, and how far it sits from its rest place.
struct OnboardingLayer: Equatable {
    var opacity: Double = 1
    var x: CGFloat = 0
    var y: CGFloat = 0

    static let rest = OnboardingLayer()
    static let hidden = OnboardingLayer(opacity: 0)

    /// Comes in from an offset and opacity 0, starting `start` seconds in.
    static func enter(
        _ elapsed: TimeInterval, at start: TimeInterval, for duration: TimeInterval,
        x: CGFloat = 0, y: CGFloat = 0, curve: CubicBezier = .settle
    ) -> OnboardingLayer {
        let p = curve.value(at: (elapsed - start) / duration)
        return OnboardingLayer(opacity: p, x: x * (1 - p), y: y * (1 - p))
    }

    /// Goes out to opacity 0 while moving to an offset.
    static func leave(
        _ elapsed: TimeInterval, at start: TimeInterval, for duration: TimeInterval,
        x: CGFloat = 0, y: CGFloat = 0, curve: CubicBezier = .settle
    ) -> OnboardingLayer {
        let p = curve.value(at: (elapsed - start) / duration)
        return OnboardingLayer(opacity: 1 - p, x: x * p, y: y * p)
    }
}

/// The action row draws at half opacity at most until input opens, then rises
/// to 1 over 200 ms.
enum OnboardingRowCap {
    static let closed = 0.5
    static let rise: TimeInterval = 0.2

    static func value(at elapsed: TimeInterval, opensAt: TimeInterval) -> Double {
        closed + (1 - closed) * CubicBezier.fade.value(at: (elapsed - opensAt) / rise)
    }
}

private func mix(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * CGFloat(p) }

/// The first-launch opening, from T0 (the stage panel ordered front): the shape
/// opens, the orb gathers, the wordmark and tagline hold long enough to read and
/// leave, then the shape folds into the band and the orb rises into its slot.
enum OpeningTimeline {
    static let swapAt: TimeInterval = 3.560
    static let dipAt: TimeInterval = 3.600
    static let end: TimeInterval = 4.100
    static let watchdog: TimeInterval = 5.0
    static let stillSwapAt: TimeInterval = 2.200

    /// The band is ordered front at alpha 0, ready for the swap.
    static let primeAt: TimeInterval = 2.8
    /// The stage leaves 40 ms after the swap, once the band has drawn.
    static let stageOutDelay: TimeInterval = 0.04
    static let shapeOpens: TimeInterval = 0.52
    static let gatherAt: TimeInterval = 0.24
    static let gatherDuration: TimeInterval = 1.0
    static let wordmarkAt: TimeInterval = 0.9
    static let taglineAt: TimeInterval = 1.1
    static let wordsIn: TimeInterval = 0.5
    static let wordsOutAt: TimeInterval = 2.7
    static let wordsOut: TimeInterval = 0.25
    static let foldAt: TimeInterval = 2.8
    static let foldDuration: TimeInterval = 0.76
    /// A skip blends from wherever the stage is to the swap frame.
    static let skipBlend: TimeInterval = 0.25
    /// The still version dissolves the hold frame in, holds it, then cross-fades.
    static let stillHoldFrame: TimeInterval = 2.0
    static let stillFade: TimeInterval = 0.2

    /// Where the shape grows from and folds to on one display.
    struct Geometry: Equatable {
        var startWidth: CGFloat
        var stageWidth: CGFloat
        var bandWidth: CGFloat

        init(_ geometry: NotchGeometry, layout: NotchOnboardingLayout) {
            startWidth = geometry.hasNotch ? geometry.notchWidth : layout.fallbackBodyWidth
            stageWidth = layout.stagePanelSize(for: geometry).width
            bandWidth = layout.surfaceWidth(for: geometry)
        }
    }

    struct Frame: Equatable {
        var width: CGFloat
        /// Below the notch.
        var depth: CGFloat
        var bottomRadius: CGFloat
        var orbDiameter: CGFloat
        /// Below the notch.
        var orbCenterY: CGFloat
        var orbGather: Double
        var wordmark: OnboardingLayer
        var tagline: OnboardingLayer
        /// The whole stage; below 1 only in the still version's fades.
        var opacity: Double = 1
    }

    /// The band at rest. The stage reaches it at the swap, so nothing moves when
    /// the two panels change places.
    static func swapFrame(_ g: Geometry, layout: NotchOnboardingLayout) -> Frame {
        Frame(
            width: g.bandWidth, depth: layout.thickness, bottomRadius: layout.bottomCornerRadius,
            orbDiameter: layout.orbDiameter, orbCenterY: layout.orbCenterY, orbGather: 1,
            wordmark: .hidden, tagline: .hidden)
    }

    static func frame(
        at t: TimeInterval, _ g: Geometry, layout: NotchOnboardingLayout, policy: OnboardingMotionPolicy
    ) -> Frame {
        guard policy.layers == .full else {
            var hold = moving(at: stillHoldFrame, g, layout: layout)
            let fadeIn = CubicBezier.fade.value(at: t / stillFade)
            let fadeOut = CubicBezier.fade.value(at: (t - stillSwapAt) / stillFade)
            hold.opacity = fadeIn * (1 - fadeOut)
            return hold
        }
        return moving(at: t, g, layout: layout)
    }

    /// `elapsed` after a skip that came `from` this frame.
    static func skipFrame(
        at elapsed: TimeInterval, from start: Frame, _ g: Geometry, layout: NotchOnboardingLayout
    ) -> Frame {
        let end = swapFrame(g, layout: layout)
        let p = CubicBezier.settle.value(at: elapsed / skipBlend)
        func layer(_ a: OnboardingLayer) -> OnboardingLayer {
            OnboardingLayer(opacity: a.opacity * (1 - p), x: a.x * CGFloat(1 - p), y: a.y * CGFloat(1 - p))
        }
        return Frame(
            width: mix(start.width, end.width, p), depth: mix(start.depth, end.depth, p),
            bottomRadius: mix(start.bottomRadius, end.bottomRadius, p),
            orbDiameter: mix(start.orbDiameter, end.orbDiameter, p),
            orbCenterY: mix(start.orbCenterY, end.orbCenterY, p),
            orbGather: start.orbGather + (1 - start.orbGather) * p,
            wordmark: layer(start.wordmark), tagline: layer(start.tagline),
            opacity: start.opacity + (1 - start.opacity) * p)
    }

    private static func moving(at t: TimeInterval, _ g: Geometry, layout: NotchOnboardingLayout) -> Frame {
        let open = CubicBezier.settle.value(at: t / shapeOpens)
        let fold = CubicBezier.settle.value(at: (t - foldAt) / foldDuration)
        func words(_ start: TimeInterval, rise: CGFloat) -> OnboardingLayer {
            let enter = OnboardingLayer.enter(t, at: start, for: wordsIn, y: rise)
            let leave = OnboardingLayer.leave(t, at: wordsOutAt, for: wordsOut, y: -6)
            return OnboardingLayer(opacity: enter.opacity * leave.opacity, y: enter.y + leave.y)
        }
        return Frame(
            width: mix(mix(g.startWidth, g.stageWidth, open), g.bandWidth, fold),
            depth: mix(mix(0, layout.stageDepth, open), layout.thickness, fold),
            bottomRadius: mix(
                mix(layout.topConcaveRadius, layout.stageBottomRadius, open), layout.bottomCornerRadius, fold),
            orbDiameter: mix(layout.stageOrbDiameter, layout.orbDiameter, fold),
            orbCenterY: mix(layout.stageOrbCenterY, layout.orbCenterY, fold),
            orbGather: CubicBezier.settle.value(at: (t - gatherAt) / gatherDuration),
            wordmark: words(wordmarkAt, rise: 10), tagline: words(taglineAt, rise: 8))
    }
}

/// The band's content fading up: at the swap after the stage, or at once with
/// no stage, where the orb also gathers because no stage brought it.
enum BandReveal {
    /// Input opens here, 540 ms in (4,100 ms after the stage).
    static let opensAt: TimeInterval = 0.54
    /// Under the still version the band shows at rest and input opens 300 ms later.
    static let stillOpensAt: TimeInterval = 0.3
    static let layer: TimeInterval = 0.32
    static let headlineAt: TimeInterval = 0.08
    static let bodyAt: TimeInterval = 0.14
    static let actionsAt: TimeInterval = 0.22
    static let rise: CGFloat = 6
    /// After the stage, the orb dips to the beat-1 figure 40 ms into the reveal.
    static let dipAt: TimeInterval = 0.04

    struct Frame: Equatable {
        /// The step dots and the top bar.
        var chrome = OnboardingLayer.rest
        var headline = OnboardingLayer.rest
        var body = OnboardingLayer.rest
        var actions = OnboardingLayer.rest
        var rowCap: Double = 1
        var orbGather: Double = 1

        static let rest = Frame()
    }

    static func inputOpens(policy: OnboardingMotionPolicy) -> TimeInterval {
        policy.layers == .full ? opensAt : stillOpensAt
    }

    static func duration(policy: OnboardingMotionPolicy) -> TimeInterval {
        inputOpens(policy: policy) + OnboardingRowCap.rise
    }

    static func frame(at elapsed: TimeInterval, gathers: Bool, policy: OnboardingMotionPolicy) -> Frame {
        let cap = OnboardingRowCap.value(at: elapsed, opensAt: inputOpens(policy: policy))
        guard policy.layers == .full else { return Frame(rowCap: cap) }
        return Frame(
            chrome: .enter(elapsed, at: 0, for: layer, y: rise),
            headline: .enter(elapsed, at: headlineAt, for: layer, y: rise),
            body: .enter(elapsed, at: bodyAt, for: layer, y: rise),
            actions: .enter(elapsed, at: actionsAt, for: layer, y: rise),
            rowCap: cap,
            orbGather: gathers ? CubicBezier.settle.value(at: elapsed / opensAt) : 1)
    }
}

/// A move from one beat to the next: the old copy slides out, the new copy
/// slides in a line at a time, and the ember bead slides along the step dots.
/// Back mirrors forward.
enum BeatTransition {
    static let outDuration: TimeInterval = 0.2
    static let slide: CGFloat = 14
    static let headlineAt: TimeInterval = 0.12
    static let bodyAt: TimeInterval = 0.17
    static let actionsAt: TimeInterval = 0.22
    static let inDuration: TimeInterval = 0.28
    static let opensAt: TimeInterval = 0.5
    static let stillOpensAt: TimeInterval = 0.3

    struct Frame: Equatable {
        /// The previous beat's copy, row and held bloom, leaving together.
        var outgoing: OnboardingLayer
        var headline: OnboardingLayer
        var body: OnboardingLayer
        var actions: OnboardingLayer
        /// How far the bead has slid from the old step to the new one.
        var bead: Double
        var rowCap: Double
    }

    static func duration(policy: OnboardingMotionPolicy) -> TimeInterval {
        (policy.layers == .full ? opensAt : stillOpensAt) + OnboardingRowCap.rise
    }

    static func frame(at elapsed: TimeInterval, backward: Bool = false, policy: OnboardingMotionPolicy) -> Frame {
        guard policy.layers == .full else {
            return Frame(
                outgoing: .hidden, headline: .rest, body: .rest, actions: .rest, bead: 1,
                rowCap: OnboardingRowCap.value(at: elapsed, opensAt: stillOpensAt))
        }
        let way: CGFloat = backward ? -1 : 1
        return Frame(
            outgoing: .leave(elapsed, at: 0, for: outDuration, x: -slide * way, curve: .fade),
            headline: .enter(elapsed, at: headlineAt, for: inDuration, x: slide * way),
            body: .enter(elapsed, at: bodyAt, for: inDuration, x: slide * way),
            actions: .enter(elapsed, at: actionsAt, for: inDuration, x: slide * way),
            bead: CubicBezier.settle.value(at: elapsed / Theme.Motion.settleDuration),
            rowCap: OnboardingRowCap.value(at: elapsed, opensAt: opensAt))
    }
}

/// A change inside one beat: the copy cross-fades and the row swaps. A grant's
/// badge also draws its check ring and then its glyph.
enum Flourish {
    static let rowSwap: TimeInterval = 0.12
    static let copySwap: TimeInterval = 0.2
    static let ringDuration: TimeInterval = 0.36
    static let glyphAt: TimeInterval = 0.2
    static let glyphDuration: TimeInterval = 0.24
    static let opensAt: TimeInterval = 0.3
    /// The bloom is the last layer to settle.
    static let duration: TimeInterval = OnboardingBloom.startsAt + OnboardingBloom.duration

    struct Frame: Equatable {
        var oldCopy: Double
        var newCopy: Double
        var oldRow: Double
        var newRow: Double
        /// Trim of the badge's ring and of its check glyph.
        var ring: Double
        var glyph: Double
        var rowCap: Double
    }

    /// The still version changes in place: the badge appears whole.
    static func frame(at elapsed: TimeInterval, policy: OnboardingMotionPolicy) -> Frame {
        let cap = OnboardingRowCap.value(at: elapsed, opensAt: opensAt)
        guard policy.layers == .full else {
            return Frame(oldCopy: 0, newCopy: 1, oldRow: 0, newRow: 1, ring: 1, glyph: 1, rowCap: cap)
        }
        let copy = CubicBezier.fade.value(at: elapsed / copySwap)
        let row = CubicBezier.fade.value(at: elapsed / rowSwap)
        return Frame(
            oldCopy: 1 - copy, newCopy: copy, oldRow: 1 - row, newRow: row,
            ring: CubicBezier.settle.value(at: elapsed / ringDuration),
            glyph: CubicBezier.settle.value(at: (elapsed - glyphAt) / glyphDuration),
            rowCap: cap)
    }
}

/// Done, or Close and open Settings: the content fades, then the band folds back
/// into the notch while the orb gathers in. The still version is a cut.
enum Outro {
    static let contentOut: TimeInterval = 0.15
    static let foldAt: TimeInterval = 0.1
    static let foldDuration: TimeInterval = 0.3
    static let end: TimeInterval = 0.4

    struct Frame: Equatable {
        /// Everything on the band except the orb.
        var content: Double
        /// 0 is the band at rest, 1 is folded into the notch.
        var fold: Double
        var orbGather: Double
    }

    static func duration(policy: OnboardingMotionPolicy) -> TimeInterval {
        policy.layers == .full ? end : 0
    }

    static func frame(at elapsed: TimeInterval) -> Frame {
        let fold = CubicBezier.settle.value(at: (elapsed - foldAt) / foldDuration)
        return Frame(content: 1 - CubicBezier.fade.value(at: elapsed / contentOut), fold: fold, orbGather: 1 - fold)
    }
}
