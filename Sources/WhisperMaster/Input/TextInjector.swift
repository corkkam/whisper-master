import AppKit
import CoreGraphics

actor TextInjector {
    func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        let chunkSize = 20

        for start in stride(from: 0, to: utf16.count, by: chunkSize) {
            let end = min(start + chunkSize, utf16.count)
            let slice = Array(utf16[start..<end])
            postEvent(source: source, slice: slice, keyDown: true)
            postEvent(source: source, slice: slice, keyDown: false)
        }
    }

    /// Synthesize a Command-V paste. Unlike `inject` (per-character Unicode key
    /// events, which web/Electron content silently drops), this is a *real*
    /// system paste that goes through the app's paste handler, so it lands in
    /// browsers, Electron apps, terminals, and native fields alike. The caller
    /// must put the text on the pasteboard first.
    func pressCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V
        postKey(source: source, virtualKey: vKey, keyDown: true, flags: .maskCommand)
        postKey(source: source, virtualKey: vKey, keyDown: false, flags: .maskCommand)
    }

    /// Synthesize `count` backspace keystrokes (virtual key 0x33) at the current
    /// caret, used to walk back over text we ourselves just typed before retyping
    /// a refined suffix. Caller is responsible for confirming the caret is where
    /// it thinks it is (see `InPlaceRefiner`).
    func deleteBackward(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            postKey(source: source, virtualKey: 0x33, keyDown: true)
            postKey(source: source, virtualKey: 0x33, keyDown: false)
        }
    }

    /// Synthesize `count` Left-arrow presses (virtual key 0x7B), optionally
    /// holding Shift to *extend the selection* — used to select exactly the
    /// region we pasted before pasting a whole-sentence refinement over it.
    func moveLeft(_ count: Int, selecting: Bool) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = selecting ? .maskShift : []
        for _ in 0..<count {
            postKey(source: source, virtualKey: 0x7B, keyDown: true, flags: flags)
            postKey(source: source, virtualKey: 0x7B, keyDown: false, flags: flags)
        }
    }

    private func postKey(
        source: CGEventSource?, virtualKey: CGKeyCode, keyDown: Bool, flags: CGEventFlags = []
    ) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown)
        else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func postEvent(source: CGEventSource?, slice: [UniChar], keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { return }
        event.flags = []
        slice.withUnsafeBufferPointer { pointer in
            event.keyboardSetUnicodeString(
                stringLength: slice.count,
                unicodeString: pointer.baseAddress
            )
        }
        event.post(tap: .cghidEventTap)
    }
}
