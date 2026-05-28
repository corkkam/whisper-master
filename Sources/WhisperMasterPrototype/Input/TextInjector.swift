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
