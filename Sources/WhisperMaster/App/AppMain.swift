import AppKit
import Foundation

@main
struct WhisperMasterApp {
    @MainActor
    static func main() {
        // Hidden snapshot mode for design iteration: render the UI to PNGs and
        // exit without launching the full menu-bar app. Triggered by setting
        // WM_SNAPSHOT to an output directory. DEBUG-only — excluded from
        // shipping Release builds.
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["WM_SNAPSHOT"] {
            SnapshotMode.run(outputDirectory: dir)
            return
        }
        #endif

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
