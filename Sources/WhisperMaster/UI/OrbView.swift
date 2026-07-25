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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Entry pop (mirrors the old orb's appearance beat).
    @State private var appeared = false

    /// Map the mic level to the wave's amplitude gain. Quiet speech still shows a
    /// gentle wave; loud speech swells it. `level * 18` matches the old orb's
    /// level→activity mapping.
    private var waveGain: Double {
        let activity = Double(min(1, max(0, level * 18)))
        return 0.35 + 1.05 * activity
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
            preset: .small,
            dark: true,
            speed: 1,
            extraOpts: mode == .listening ? ["gain": waveGain] : [:]
        )
        .scaleEffect(reduceMotion || appeared ? 1 : 0.86)
        .opacity(reduceMotion || appeared ? 1 : 0)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(Theme.Motion.appear) { appeared = true }
        }
    }
}
