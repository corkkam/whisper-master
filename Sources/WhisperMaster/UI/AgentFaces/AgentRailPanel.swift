import AppKit
import SwiftUI

/// What the rail shows. The panel writes it; `AgentRailHost` reads it, so an
/// update changes values and never swaps the hosting view's root.
@MainActor
@Observable
final class AgentRailModel {
    var items: [AgentRailItem] = []
    var hoveredID: String?
    var reducedMotion = false
    /// Face frames in the panel's top-left coordinates, for hit testing.
    @ObservationIgnored var faceFrames: [String: CGRect] = [:]
}

private struct AgentRailHost: View {
    let model: AgentRailModel
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            AgentRailView(
                items: model.items, reducedMotion: model.reducedMotion,
                hoveredID: model.hoveredID, onSelect: onSelect,
                onFaceFrames: { model.faceFrames = $0 })
        }
        .frame(width: AgentRailView.labelRoom + AgentRailView.width)
        .coordinateSpace(name: AgentRailView.space)
    }
}

/// Owns the borderless, non-activating panel that shows the agent rail at the
/// right edge of the display under the pointer. It copies the notch band's
/// window settings (`DictationPillWindow`): status-bar level, every Space, over
/// full-screen apps, never key.
///
/// The panel is click-through except on a face. Its transparent left part holds
/// the hover label, so it must not take clicks: a mouse-moved monitor decides
/// which face, if any, is under the pointer, and flips `ignoresMouseEvents` only
/// on a change. Nothing polls. With no items the window is ordered out and the
/// monitors are removed, so an empty rail costs nothing.
@MainActor
final class AgentRailPanel {
    private let panel: NSPanel
    private let host: NSHostingView<AgentRailHost>
    private let model = AgentRailModel()

    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var appliedScreenNumber: NSNumber?
    private var appliedFrame: NSRect?
    private var appliedDark: Bool?
    /// When each agent entered its current state, for items that came without `since`.
    private var entered: [String: (state: AgentFaceState, at: Date)] = [:]

    /// Distance from the screen's right edge.
    static let edgeInset: CGFloat = 8

    init(onSelect: @escaping (String) -> Void = { _ in }) {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        // The global monitor does not see moves inside our own window, so the
        // local one needs them to notice the pointer leaving a face.
        panel.acceptsMouseMovedEvents = true

        host = NSHostingView(rootView: AgentRailHost(model: model, onSelect: onSelect))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible }

    /// Show these agents, or close the rail when there are none.
    func update(items: [AgentRailItem]) {
        let now = Date()
        var stamped = items
        for i in stamped.indices {
            let item = stamped[i]
            if let prior = entered[item.id], prior.state == item.state {
                if stamped[i].since == nil { stamped[i].since = prior.at }
            } else {
                entered[item.id] = (item.state, item.since ?? now)
                if stamped[i].since == nil { stamped[i].since = now }
            }
        }
        let ids = Set(items.map(\.id))
        entered = entered.filter { ids.contains($0.key) }

        if model.items != stamped { model.items = stamped }
        let reduced = Self.motionIsReduced()
        if model.reducedMotion != reduced { model.reducedMotion = reduced }

        if stamped.isEmpty {
            close()
        } else {
            open()
            reposition()
        }
    }

    // MARK: Window

    private func open() {
        applyAppearance()
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless()
        installMonitors()
    }

    private func close() {
        removeMonitors()
        if model.hoveredID != nil { model.hoveredID = nil }
        if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Right edge of the pointer's display, centred in its visible frame.
    private func reposition() {
        guard let screen = PointerScreen.current() else { return }
        appliedScreenNumber = PointerScreen.number(of: screen)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: visible.maxX - size.width - Self.edgeInset,
            y: visible.midY - size.height / 2,
            width: size.width, height: size.height
        ).integral
        guard frame != appliedFrame else { return }
        appliedFrame = frame
        panel.setFrame(frame, display: true)
    }

    /// The rail sits on the desktop, not on the bezel, so it follows the system
    /// appearance (the app itself is pinned to light).
    private func applyAppearance() {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        guard dark != appliedDark else { return }
        appliedDark = dark
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    // MARK: Pointer

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
                MainActor.assumeIsolated { self?.pointerMoved() }
                return event
            }) {
            monitors.append(local)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appliedFrame = nil
                self?.reposition()
            }
        }
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let themeObserver { DistributedNotificationCenter.default().removeObserver(themeObserver) }
        screenObserver = nil
        themeObserver = nil
    }

    private func pointerMoved() {
        let pointer = NSEvent.mouseLocation
        if let screen = PointerScreen.current(pointer: pointer),
           PointerScreen.number(of: screen) != appliedScreenNumber {
            reposition()
        }
        let frame = panel.frame
        let local = CGPoint(x: pointer.x - frame.minX, y: frame.maxY - pointer.y)
        let hit = model.faceFrames.first { $0.value.contains(local) }?.key
        if model.hoveredID != hit { model.hoveredID = hit }
        let interactive = hit != nil
        guard panel.ignoresMouseEvents == interactive else { return }
        panel.ignoresMouseEvents = !interactive
    }

    /// Reduce Motion, Low Power, a hot Mac or VoiceOver: one still frame per state.
    private static func motionIsReduced() -> Bool {
        OnboardingMotionPolicy.resolve(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: ProcessInfo.processInfo.thermalState,
            voiceOver: NSWorkspace.shared.isVoiceOverEnabled
        ).layers == .still
    }
}
