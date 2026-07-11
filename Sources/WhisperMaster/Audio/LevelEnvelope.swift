import Foundation

/// A tiny attack/decay envelope follower for the mic input level.
///
/// The raw `audioLevel` written per capture buffer is steppy — it jumps to each
/// buffer's peak and snaps back to zero in the gaps between words, which makes
/// the notch wave look janky rather than alive. Feeding it through this follower
/// gives the wave a fast *attack* (it responds immediately when you start
/// speaking) and a slower *decay* (it eases down through pauses instead of
/// collapsing), so the meter reads as "breathing" and hearing you.
///
/// Pure value type — no timing, no state beyond `current` — so it's trivially
/// unit-testable (`LevelEnvelopeTests`).
struct LevelEnvelope {
    /// The current smoothed level in `0...`.
    private(set) var current: Float = 0

    /// Rise responsiveness (0…1). Higher = snaps up faster.
    let attack: Float
    /// Fall responsiveness (0…1). Lower = eases down more slowly.
    let decay: Float

    init(attack: Float = 0.55, decay: Float = 0.16) {
        self.attack = min(1, max(0, attack))
        self.decay = min(1, max(0, decay))
    }

    /// Advance toward `target`, returning the new smoothed level. Uses the
    /// attack coefficient while rising and the (slower) decay coefficient while
    /// falling.
    @discardableResult
    mutating func step(target: Float) -> Float {
        let t = max(0, target)
        let coeff = t > current ? attack : decay
        current += (t - current) * coeff
        // Clamp tiny residuals to zero so the wave can settle fully flat.
        if current < 0.0005 { current = 0 }
        return current
    }

    mutating func reset() {
        current = 0
    }
}
