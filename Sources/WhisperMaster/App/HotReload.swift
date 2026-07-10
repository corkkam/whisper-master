import SwiftUI

// Live hot reload for the running Debug app via InjectionIII. Save a view file
// and it swaps into the running app in ~1-2s (state intact, no rebuild/relaunch).
//
// **Debug-only, and it can never reach a shipped build:** the bundle load and the
// redraw observer are wrapped in `#if DEBUG`, and injection additionally needs the
// `-Xlinker -interposable` flag that `project.yml` sets on the Debug config only.
// CI builds `-configuration Release`, so none of this compiles in or runs.
//
// Setup (one time): install InjectionIII.app, run the Debug build, point Injection
// at the repo. Then any `.hotReloadable()` view redraws on save.

extension View {
    /// Redraw this view whenever a file is hot-reloaded. No-op in Release.
    @ViewBuilder
    func hotReloadable() -> some View {
        #if DEBUG
        modifier(HotReloadModifier())
        #else
        self
        #endif
    }
}

#if DEBUG
enum HotReload {
    /// Load the InjectionIII bundle so saved files inject into the running app.
    /// Silent no-op if InjectionIII isn't installed.
    static func bootstrap() {
        let path = "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle"
        if Bundle(path: path)?.load() == true {
            NSLog("[HotReload] injection bundle loaded — save a view to hot-reload")
        }
    }
}

/// Forces a SwiftUI redraw when InjectionIII reloads a file.
private final class InjectionObserver: ObservableObject {
    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(injected),
            name: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"), object: nil)
    }
    @objc private func injected() { objectWillChange.send() }
}

private struct HotReloadModifier: ViewModifier {
    @StateObject private var observer = InjectionObserver()
    func body(content: Content) -> some View { content }
}
#endif
