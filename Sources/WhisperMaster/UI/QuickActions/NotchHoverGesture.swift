import Foundation

/// Pure, deterministic recogniser for "the pointer is resting on the notch".
///
/// The notch is somewhere the pointer crosses constantly on its way to the menu
/// bar, so a panel that opened on contact would fire all day. Two hysteresis
/// windows fix that, and they are deliberately asymmetric:
/// - **`openDwell`** — the pointer has to *stay* on the notch this long before the
///   panel opens, which is what separates resting there from passing through.
/// - **`closeGrace`** — an open panel survives this long off it, which covers the
///   gap a hand crosses on the way down into the band and the jitter of a click.
///
/// `allowed` is checked on every update rather than once at the open: the dictation
/// surface can claim the notch at any moment, and when it does the panel yields
/// immediately instead of waiting out the grace.
///
/// Time is injected (`now` on every call) so the whole machine is testable without a
/// clock; `NotchQuickActionsWindow` owns the real timer.
struct NotchHoverGesture {
    /// How long the pointer has to rest on the notch before the panel opens. Short
    /// enough to feel like an answer, long enough that a pointer *travelling* to the
    /// menu bar is gone again before it counts.
    var openDwell: TimeInterval = 0.28
    /// How long the pointer has to be away before an open panel closes. Generous:
    /// once the band is up, a moment off it is far more likely to be a hand on its
    /// way back than a decision to leave, and re-earning the dwell to get it back is
    /// the annoying failure.
    var closeGrace: TimeInterval = 0.6

    private(set) var isOpen = false

    /// When the pointer arrived on the notch (`nil` while it's away).
    private var enteredAt: TimeInterval?
    /// When the pointer left the open panel (`nil` while it's on it).
    private var leftAt: TimeInterval?

    init(openDwell: TimeInterval = 0.28, closeGrace: TimeInterval = 0.6) {
        self.openDwell = openDwell
        self.closeGrace = closeGrace
    }

    /// Feed the current pointer state. `inside` means "on the thing that matters" —
    /// the notch strip while closed, the panel itself while open. `allowed` is
    /// whether the panel may be open at all. Returns true when `isOpen` changed.
    @discardableResult
    mutating func update(inside: Bool, allowed: Bool, now: TimeInterval) -> Bool {
        if isOpen {
            // Something that outranks a glance took the notch: give it back at once.
            guard allowed else { close(); return true }
            if inside {
                leftAt = nil
            } else if let leftAt {
                if now - leftAt >= closeGrace {
                    close()
                    return true
                }
            } else {
                leftAt = now
            }
            return false
        }

        guard allowed, inside else {
            // Forget any dwell in progress, so the panel can't pop the instant it
            // becomes allowed again.
            enteredAt = nil
            return false
        }
        guard let enteredAt else {
            self.enteredAt = now
            return false
        }
        guard now - enteredAt >= openDwell else { return false }
        isOpen = true
        self.enteredAt = nil
        leftAt = nil
        return true
    }

    /// Shut it now and drop all dwell state — the caller closing the panel by some
    /// other route (an action that opens the Settings window, onboarding taking the
    /// notch) so a stale dwell can't reopen it.
    mutating func close() {
        isOpen = false
        enteredAt = nil
        leftAt = nil
    }
}
