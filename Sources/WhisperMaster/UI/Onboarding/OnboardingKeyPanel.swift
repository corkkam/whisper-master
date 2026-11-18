import AppKit

/// The panel the onboarding band sits in, and the one the opening stage will
/// share: borderless, non-activating, at the dictation pill's level and
/// collection behavior, clear, no shadow, pinned to `.darkAqua` because it is
/// drawn on the physical black bezel.
///
/// For now it is the same plain panel the band always had, and it never becomes
/// key. The keyboard work makes it key-capable (only while the app is already
/// active) and filters keys and clicks in `sendEvent(_:)`; until then every
/// key goes to the app in front, as before.
final class OnboardingKeyPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        // Drawn on the physical black bezel, so it stays ink whatever the
        // app-wide light/dark setting is — and `Theme.Notch` keeps resolving
        // on-dark.
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = false
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
}
