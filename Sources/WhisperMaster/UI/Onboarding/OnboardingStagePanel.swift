import AppKit
import SwiftUI

/// The tall black stage the first launch opens on. A second panel, not the
/// band's, because it is far bigger than the band and the band's panel is sized
/// once. It sits on the display the pointer was on when it was made, holds no
/// ask, and lives until the swap (about 3.6 s) or a skip. The model's 5 s
/// watchdog ends it whatever happens to the cues.
///
/// Made only on the launch path, never for a replay or under VoiceOver. Each
/// presentation is a new object; nothing about it is persisted.
@MainActor
final class OnboardingStagePanel {
    private let panel = OnboardingKeyPanel()

    init(model: NotchOnboardingModel, screen: NSScreen, layout: NotchOnboardingLayout) {
        let geometry = NotchGeometry.measure(screen)
        let size = layout.stagePanelSize(for: geometry)
        panel.setFrame(
            NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height,
                width: size.width,
                height: size.height),
            display: false)
        let host = NSHostingView(rootView: OnboardingStageView(model: model, geometry: geometry, layout: layout))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    func show() {
        panel.orderFrontRegardless()
    }

    /// Safe to call twice.
    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
    }
}
