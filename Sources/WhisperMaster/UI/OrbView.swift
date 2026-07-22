import SwiftUI

/// The dictation "orb" that lives in the notch band — now a `ThinkingOrb` (the
/// SwiftUI port of `thinking-orbs`). One dotted, honestly-3D orb across the whole
/// working lifecycle:
///
/// - **recording** → the `listening` wave, its undulation driven by the live mic
///   level through the engine's `gain` knob (louder = bigger waves; the tempo
///   stays constant so the phase never jumps);
/// - **preparing / finalizing** → the `working` orbits (particles running tilted
///   paths), a calm "busy" indicator while there's no audio to react to.
///
/// The notch is a dark substrate, so `dark: true` renders light ink. Entry pop
/// and Reduce-Motion handling live in `ThinkingOrb` itself.
struct OrbView: View {
    let level: Float
    /// `true` while recording (audio-reactive `listening`); `false` while
    /// preparing/finalizing (calm `working`).
    var energized: Bool

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

    var body: some View {
        ThinkingOrb(
            state: energized ? .listening : .working,
            renderSize: diameter,
            preset: .small,
            dark: true,
            speed: 1,
            extraOpts: energized ? ["gain": waveGain] : [:]
        )
        .scaleEffect(reduceMotion || appeared ? 1 : 0.86)
        .opacity(reduceMotion || appeared ? 1 : 0)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(Theme.Motion.appear) { appeared = true }
        }
    }
}
