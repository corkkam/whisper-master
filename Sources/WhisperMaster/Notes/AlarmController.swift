import AppKit
import SwiftUI

/// Drives the "loud alarm" reminder style: loops the chosen system sound and
/// shows a single, focused alert window that keeps ringing until the user acts
/// (Snooze / Done). One instance, owned by `AppDelegate`; never duplicated.
///
/// Sound playback is nil-safe and restart-safe, following `App/SoundFeedback`:
/// an unresolved sound simply shows the window without audio rather than
/// crashing.
@MainActor
final class AlarmController {
    private var window: NSWindow?
    private var sound: NSSound?
    private(set) var activeReminderID: UUID?

    var isPresenting: Bool { activeReminderID != nil }

    /// Ring for `reminder`, showing the alert window. No-op (returns false) if an
    /// alarm is already up — the caller keeps that reminder "due" so it re-fires
    /// once this one is dismissed. Returns true when it took over the surface.
    @discardableResult
    func present(
        _ reminder: ReminderItem,
        onSnooze: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) -> Bool {
        guard activeReminderID == nil else { return false }
        activeReminderID = reminder.id

        startSound(named: reminder.soundName)

        let view = AlarmView(
            reminder: reminder,
            onSnooze: { [weak self] in self?.stop(); onSnooze() },
            onDone: { [weak self] in self?.stop(); onDone() }
        )
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = reminder.displayTitle
        win.styleMask = [.titled, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        // Can't be dismissed by the window chrome — only Snooze / Done.
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.setContentSize(NSSize(width: 420, height: 300))
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.hidesOnDeactivate = false
        win.isMovableByWindowBackground = true
        // Inherits the app-wide light appearance pinned in
        // `AppDelegate.applicationDidFinishLaunching`.
        win.backgroundColor = Theme.canvasNSColor
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        return true
    }

    /// Silence and dismiss the current alarm, if any.
    func stop() {
        sound?.stop()
        sound = nil
        window?.orderOut(nil)
        window = nil
        activeReminderID = nil
    }

    private func startSound(named name: String) {
        let resolved = ReminderSound.resolved(name)
        guard let s = NSSound(named: NSSound.Name(resolved)) else {
            Log.notes.error("alarm sound \(resolved, privacy: .public) unavailable — ringing silently")
            return
        }
        s.loops = true
        s.volume = 1.0
        sound = s
        s.play()
    }
}
