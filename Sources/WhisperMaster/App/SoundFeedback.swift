import AppKit

/// Non-visual feedback for the dictation lifecycle — the subtle start/stop click
/// and the delivery chime the "Play start / stop sound" setting promises, plus a
/// light trackpad haptic. Both channels are gated on that one setting so a single
/// switch governs all non-visual feedback.
///
/// System sounds are used (no bundled assets), played at a low volume so they
/// read as a quiet cue rather than an alert. Every call is nil-safe: a missing
/// sound or a Mac without a haptic engine simply does nothing.
@MainActor
enum Feedback {
    /// Recording actually began — a soft opening click.
    static func start(soundEnabled: Bool) {
        guard soundEnabled else { return }
        play("Pop", volume: 0.4)
        haptic()
    }

    /// The user released the key / toggled off — a soft closing click.
    static func stop(soundEnabled: Bool) {
        guard soundEnabled else { return }
        play("Tink", volume: 0.4)
        haptic()
    }

    /// The transcript landed at the cursor — a brief confirming chime. This is
    /// the "it worked, you can look away" beat.
    static func delivered(soundEnabled: Bool) {
        guard soundEnabled else { return }
        play("Glass", volume: 0.3)
        haptic()
    }

    // MARK: - Internals

    private static var cache: [String: NSSound] = [:]

    private static func play(_ name: String, volume: Float) {
        let sound: NSSound?
        if let cached = cache[name] {
            sound = cached
        } else {
            sound = NSSound(named: NSSound.Name(name))
            cache[name] = sound
        }
        guard let sound else { return }
        sound.stop()            // restart cleanly if it's still ringing
        sound.volume = volume
        sound.play()
    }

    private static func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }
}
