import AppKit

/// The play/pause key on the keyboard, pressed in software.
///
/// macOS routes this to whichever app currently holds "now playing", which is what
/// makes it the one mechanism that reaches Music, Spotify and a video in any
/// browser without asking each of them separately. It needs Accessibility, which
/// this app already requires for `TextInjector` — a build without that grant cannot
/// type either, so nothing new is asked of the user.
///
/// The private MediaRemote framework would let us send an explicit *pause* rather
/// than a toggle, and was rejected: since macOS 15.4 it refuses commands from any
/// process without an Apple-issued entitlement, so it would fail silently on
/// exactly the machines the app runs on.
@MainActor
enum MediaKey {
    /// `NX_KEYTYPE_PLAY` from `IOKit/hidsystem/ev_keymap.h`. Spelled out here so the
    /// SwiftPM build does not depend on that header being importable.
    private static let playPause: Int32 = 16

    /// Press and release. A key-down with no key-up leaves some players waiting for
    /// the rest of the gesture and doing nothing.
    static func sendPlayPause() {
        post(down: true)
        post(down: false)
    }

    private static func post(down: Bool) {
        let state = down ? 0x0A00 : 0x0B00
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,                       // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: Int((playPause << 16) | Int32(state)),
            data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
