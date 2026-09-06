import AppKit
import Foundation

@main
struct WhisperMasterApp {
    @MainActor
    static func main() {
        // Register the bundled brand faces (Bricolage Grotesque / Instrument
        // Sans) with Core Text
        // before any UI renders, so both the app and the snapshot path use them
        // (falls back to system faces if a file is missing).
        BrandFont.registerAll()

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

        // The assistant suite: the hand-rolled JSON prompt against the model's native
        // tool-calling, on the real qwen. Same early-exit posture as the snapshot hook
        // — before any AppKit, TCC or mesh setup — which is what lets this one run
        // headless by exec'ing the binary, unlike EvalRunner.
        //
        // NOT behind `#if DEBUG`, deliberately, and for the same reason EvalRunner is
        // not: `Scripts/release.sh` grades the bundle it just built, and that bundle
        // is Release. A suite that only exists in Debug cannot grade a release. The
        // hook is inert unless WM_AGENT_TOOL_EVAL is set.
        if ProcessInfo.processInfo.environment["WM_AGENT_TOOL_EVAL"] != nil {
            // Pump the main run loop (which services the main actor) until the async
            // harness finishes — a semaphore would deadlock the main-actor work the
            // harness schedules. The heavy MLX compute runs on `MlxCleanupService`'s
            // own actor, off main, so pumping stays responsive between awaits.
            let done = AgentToolEval.Done()
            Task { @MainActor in
                await AgentToolEval.run()
                done.set()
            }
            while !done.get() {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            return
        }

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
