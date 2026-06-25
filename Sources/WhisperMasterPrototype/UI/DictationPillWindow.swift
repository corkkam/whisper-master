import AppKit
import SwiftUI

/// Owns the borderless, click-through panel that hosts the notch dictation
/// surface, keeping it anchored to the notch as displays change.
@MainActor
final class DictationPillWindow {
    private let panel: NSPanel
    private let host: NSHostingView<PrototypePillView>
    private let state: PrototypeAppState
    private let layout = NotchSurfaceLayout()

    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init(state: PrototypeAppState) {
        self.state = state

        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true

        host = NSHostingView(rootView: PrototypePillView(state: state))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        observeEnvironment()
        reposition()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Prefer the display that actually has a notch; fall back to the main one.
    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func reposition() {
        guard let screen = targetScreen else { return }

        let geometry = NotchGeometry.measure(screen)
        let size = layout.panelSize(for: geometry)
        let origin = layout.panelOrigin(for: geometry, on: screen)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        host.rootView = PrototypePillView(state: state, geometry: geometry, layout: layout)
    }

    private func observeEnvironment() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reposition()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reposition()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
