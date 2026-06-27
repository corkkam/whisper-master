import AppKit
import Foundation

@main
struct WhisperMasterPrototypeApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .regular shows a Dock icon (and an app menu). The menu-bar status
        // item is still the primary surface, but macOS hides it when the menu
        // bar is crowded, so the Dock icon is the reliable way back in.
        app.setActivationPolicy(.regular)
        app.run()
    }
}
