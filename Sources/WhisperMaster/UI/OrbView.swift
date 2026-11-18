import SwiftUI

/// The dictation "orb" that lives in the notch band — a `ThinkingOrb` (the
/// SwiftUI port of `thinking-orbs`). One dotted, honestly-3D orb across the whole
/// working lifecycle, changing figure with what the app is actually doing:
///
/// - **listening** (recording) → the `listening` wave, its undulation driven by
///   the live mic level through the engine's `gain` knob (louder = bigger waves;
///   the tempo stays constant so the phase never jumps);
/// - **working** (preparing / finalizing) → the `working` orbits (particles
///   running tilted paths), a calm "busy" indicator while there's no audio to
///   react to;
/// - **thinking** (on-device polish) → the `solving` scramble, so the beat where
///   the model is rewriting the transcript reads as thought rather than as more
///   of the same waiting.
///
/// The notch is a dark substrate, so `dark: true` renders light ink. Entry pop
/// and Reduce-Motion handling live in `ThinkingOrb` itself.
struct OrbView: View {
    /// What the orb is depicting. Mapped to a `ThinkingOrb` figure below.
    enum Mode {
        case listening
        case working
        case thinking
    }

    let level: Float
    var mode: Mode = .working

    /// Rendered edge length. The dot field fills this square.
    var diameter: CGFloat = 32

    /// Which baked density/speed tuning to draw. The notch band uses the
    /// inline-scale `small` design; the onboarding band's hero orb is big enough
    /// to want the `large` one (they are separate designs, not a scale factor).
    var preset: OrbPreset = .small

    /// Play the entry pop. Off where the caller already stages the orb's arrival
    /// (onboarding's band orb), which also overrides Reduce Motion's read.
    var entrance: Bool = true
    /// Draw this instant instead of the wall clock (see `OrbTime`).
    var time: Double? = nil
    /// Force the one static frame (see `OrbTime`).
    var staticFrame: Bool = false
    /// The listening wave's gain, in place of the mapping from `level`.
    /// Onboarding passes `OnboardingOrbGain` here, which is 0 until a voice is
    /// heard. `nil` keeps the dictation band's own mapping.
    var gain: Double? = nil
    /// How far the dots have spread out of the centre (see `ThinkingOrb.gather`).
    var gather: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Entry pop (mirrors the old orb's appearance beat).
    @State private var appeared = false

    /// Map the mic level to the wave's amplitude gain. Quiet speech still shows a
    /// gentle wave; loud speech swells it.
    nonisolated static func waveGain(level: Float) -> Double {
        0.35 + 1.05 * waveActivity(level)
    }

    /// `level * 18` matches the old orb's level→activity mapping.
    nonisolated static func waveActivity(_ level: Float) -> Double {
        Double(min(1, max(0, level * 18)))
    }

    private var orbState: OrbState {
        switch mode {
        case .listening: return .listening
        case .working: return .working
        case .thinking: return .solving
        }
    }

    var body: some View {
        ThinkingOrb(
            state: orbState,
            renderSize: diameter,
            preset: preset,
            dark: true,
            speed: 1,
            extraOpts: mode == .listening ? ["gain": gain ?? Self.waveGain(level: level)] : [:],
            time: time,
            staticFrame: staticFrame,
            gather: gather
        )
        .scaleEffect(!entrance || reduceMotion || appeared ? 1 : 0.86)
        .opacity(!entrance || reduceMotion || appeared ? 1 : 0)
        .onAppear {
            guard entrance, !reduceMotion else { return }
            withAnimation(Theme.Motion.appear) { appeared = true }
        }
    }
}
