import AppKit
import ApplicationServices

/// Reads browser window titles, so a browser holding the mic can be told apart
/// as "Google Meet" rather than a voice search.
///
/// Uses the Accessibility grant the app already holds for pasting; without it
/// this returns nothing and only native call apps are detected. A browser exposes
/// the **front tab** of each window as its title, so a Meet tab behind another
/// tab is missed — the calendar fallback in `CallDetector` covers most of that.
/// Read-only, and only called for browsers already on the mic, never on a timer
/// of its own.
enum BrowserMeetingProbe {
    /// Window titles for every running app in `family` (a bundle prefix).
    static func windowTitles(family: String) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return id == family || id.hasPrefix(family + ".") && !id.contains("helper")
        }
        return apps.flatMap { titles(pid: $0.processIdentifier) }
    }

    private static func titles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement]
        else { return [] }
        return windows.compactMap { window in
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success
            else { return nil }
            return titleValue as? String
        }
    }
}
