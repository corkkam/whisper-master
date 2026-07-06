import Foundation
import IOKit.pwr_mgt

// MARK: - SleepPreventer
//
// Holds a macOS power assertion that keeps the system from *idle*-sleeping while
// something needs the Mac reachable — used so a remote (phone) dictation session
// isn't cut off when the screen is locked, and (opt-in) so the phone can start a
// session even after the Mac has sat locked and idle a while.
//
// Reference-counted: two independent reasons compose without stomping each other
// — an active remote session and the always-on "stay reachable" setting each take
// a hold, and the single underlying assertion lives as long as any hold does.
//
// `kIOPMAssertPreventUserIdleSystemSleep` prevents system idle sleep (the display
// may still sleep, which is fine); it works on battery and needs no entitlement,
// so it's compatible with the hardened runtime. It does NOT defeat lid-close
// sleep — that's an OS limitation and intentionally out of scope.

@MainActor
final class SleepPreventer {
    private var holds = 0
    private var assertionID: IOPMAssertionID = 0

    private static let reason = "Whisper Master remote dictation" as CFString

    /// Take a hold. The first hold creates the assertion.
    func acquire() {
        holds += 1
        guard holds == 1 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.reason,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
        } else {
            // Couldn't create it — undo the count so a later acquire retries.
            holds -= 1
            NSLog("SleepPreventer: failed to create assertion (\(result))")
        }
    }

    /// Release a hold. The last release drops the assertion.
    func release() {
        guard holds > 0 else { return }
        holds -= 1
        guard holds == 0, assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }
}
