import Foundation

/// Pure, deterministic gesture recogniser for the push-to-talk key.
///
/// Three gestures come off one modifier key:
/// - **hold** — press, speak, release. The default push-to-talk, and the reason
///   `.start` is emitted on the *press*: the recording must begin at the key-down
///   instant, never after a wait-and-see delay.
/// - **double-tap** — two quick taps latch the running recording *hands-free*, so
///   the key can be let go and dictation keeps going.
/// - **double-tap again** — ends a hands-free session (as does a deliberate hold,
///   an escape hatch for anyone who doesn't land the second tap).
///
/// The one place this costs something: a lone quick tap can't be resolved at the
/// release, because a second tap arriving right after would have made it a latch.
/// So a tap's stop is *deferred* by `doubleTapWindow` and resolved by `flush`.
/// That only ever extends a sub-`tapMaxHold` recording by a fraction of a second,
/// which captures a few more trailing frames rather than losing any.
///
/// Time is injected (`now` on every call) so the whole machine is testable without
/// a clock; `HotkeyManager` owns the real timer that drives `flush`.
struct HotkeyGesture {
    enum Signal: Equatable {
        /// Begin a recording.
        case start
        /// End the current recording (and drop out of hands-free).
        case stop
        /// The recording already running becomes hands-free — the key is no longer
        /// what is holding it open.
        case handsFreeOn
    }

    /// Longest press still read as a *tap* rather than a hold.
    var tapMaxHold: TimeInterval = 0.35
    /// Longest gap from a tap's release to the next press for the two to count as
    /// a double-tap.
    var doubleTapWindow: TimeInterval = 0.4

    /// True while a double-tap has latched the session open.
    private(set) var isHandsFree = false
    /// When a `flush` at or after this instant resolves a lone tap into the stop
    /// that was deferred while waiting for a possible second tap. `nil` when
    /// nothing is pending — the manager reads it to decide whether to arm a timer.
    private(set) var pendingStopAt: TimeInterval?

    private var pressedAt: TimeInterval?
    private var lastTapEndedAt: TimeInterval?
    /// Set when a press has already produced its signal, so the matching release
    /// must not produce a second one (the closing tap of a double-tap).
    private var swallowNextRelease = false

    init(tapMaxHold: TimeInterval = 0.35, doubleTapWindow: TimeInterval = 0.4) {
        self.tapMaxHold = tapMaxHold
        self.doubleTapWindow = doubleTapWindow
    }

    mutating func press(now: TimeInterval) -> Signal? {
        let isSecondTap = lastTapEndedAt.map { now - $0 <= doubleTapWindow } ?? false
        lastTapEndedAt = nil
        pressedAt = now

        if isHandsFree {
            guard isSecondTap else { return nil }
            // The closing tap of the stop gesture. Ended on the press rather than
            // the release so the key feels immediate.
            clearLatch()
            swallowNextRelease = true
            return .stop
        }

        if isSecondTap {
            // The opening tap already started a recording and its stop is still
            // deferred — keep it running and take the key out of the loop.
            pendingStopAt = nil
            isHandsFree = true
            swallowNextRelease = true
            return .handsFreeOn
        }

        // A press outside any double-tap window supersedes a deferred stop the
        // timer hasn't got to yet (jitter only — the window has already elapsed).
        // Dropping it is safe: this press's own release still ends the recording.
        pendingStopAt = nil
        return .start
    }

    mutating func release(now: TimeInterval) -> Signal? {
        let pressed = pressedAt
        pressedAt = nil

        if swallowNextRelease {
            swallowNextRelease = false
            return nil
        }
        // A release with no press we saw (key was already down when the monitor
        // was installed, or the gesture was reset mid-hold).
        guard let pressed else { return nil }
        let wasTap = (now - pressed) < tapMaxHold

        if isHandsFree {
            if wasTap {
                // Possibly the opening tap of the stop gesture; on its own it
                // changes nothing.
                lastTapEndedAt = now
                return nil
            }
            clearLatch()
            return .stop
        }

        if wasTap {
            lastTapEndedAt = now
            pendingStopAt = now + doubleTapWindow
            return nil
        }
        return .stop
    }

    /// Resolves a deferred stop once the double-tap window has passed. Safe to
    /// call at any time — a stale or early call is a no-op.
    mutating func flush(now: TimeInterval) -> Signal? {
        if let deadline = pendingStopAt, now >= deadline {
            pendingStopAt = nil
            lastTapEndedAt = nil
            // The key is down again: that press owns the session now, so its
            // release is what ends it.
            guard pressedAt == nil else { return nil }
            return .stop
        }
        if let last = lastTapEndedAt, now - last > doubleTapWindow {
            lastTapEndedAt = nil
        }
        return nil
    }

    /// Drop all gesture state — used when the recording ends by some other route
    /// (tray, failure, hotkey change) so a stale latch can't outlive its session.
    mutating func reset() {
        clearLatch()
        pressedAt = nil
        swallowNextRelease = false
    }

    private mutating func clearLatch() {
        isHandsFree = false
        pendingStopAt = nil
        lastTapEndedAt = nil
    }
}
