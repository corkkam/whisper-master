import AppKit

/// The transport keys on the keyboard, pressed in software.
///
/// macOS routes these to whichever app currently holds "now playing", which is what
/// makes them the one mechanism that reaches Music, Spotify and a video in any
/// browser without asking each of them separately. They need Accessibility, which
/// this app already requires for `TextInjector` — a build without that grant cannot
/// type either, so nothing new is asked of the user.
///
/// The private MediaRemote framework would let us send an explicit *pause* rather
/// than a toggle, and was rejected on evidence: dlopened on this machine it reports
/// "nothing is playing" while a player is audibly running, and its commands are
/// accepted and ignored. Apple gated it behind an entitlement in macOS 15.4. Don't
/// reach for it to fix the toggle.
@MainActor
enum MediaKey {
    /// Key codes from `IOKit/hidsystem/ev_keymap.h`, spelled out so the SwiftPM
    /// build does not depend on that header being importable.
    enum Key: Int32 {
        case playPause = 16     // NX_KEYTYPE_PLAY
        case next = 17          // NX_KEYTYPE_NEXT
        case previous = 18      // NX_KEYTYPE_PREVIOUS
    }

    /// Press and release. A key-down with no key-up leaves some players waiting for
    /// the rest of the gesture and doing nothing.
    static func send(_ key: Key) {
        post(key, down: true)
        post(key, down: false)
    }

    private static func post(_ key: Key, down: Bool) {
        let state = down ? 0x0A00 : 0x0B00
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,                       // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: Int((key.rawValue << 16) | Int32(state)),
            data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
