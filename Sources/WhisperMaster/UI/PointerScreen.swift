import AppKit

/// The display the pointer is on. Notch surfaces follow this so a multi-monitor
/// setup shows the band on the screen being used, not the first notched one.
enum PointerScreen {
    /// How often windows re-check which display the pointer is on.
    /// Screen changes are infrequent; this is just "did they move to the other monitor?"
    static let followInterval: TimeInterval = 0.25

    /// Index of the frame that contains `point`, or `nil` if it sits in a gap.
    static func index(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    static func current(
        pointer: CGPoint = NSEvent.mouseLocation,
        screens: [NSScreen] = NSScreen.screens,
        fallback: NSScreen? = NSScreen.main
    ) -> NSScreen? {
        if let i = index(containing: pointer, in: screens.map(\.frame)) {
            return screens[i]
        }
        return fallback
    }

    /// Stable identity for change-guarding reposition.
    static func number(of screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }
}
