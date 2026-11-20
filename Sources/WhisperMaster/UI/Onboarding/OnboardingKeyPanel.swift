import AppKit

/// The panel the onboarding band and the opening stage sit in: borderless,
/// non-activating, at the dictation pill's level and collection behavior, clear,
/// no shadow, pinned to `.darkAqua` because it is drawn on the physical black
/// bezel.
///
/// It can take the keyboard, but only on two terms. It becomes key on its own
/// (`makeKeyIfActive()`) only while our app is already active, so it never takes
/// keys from the app in front; and a click on it, once input is open, makes it
/// key, because the click is the user choosing it. It never activates the app.
///
/// `sendEvent(_:)` filters every key and click: a repeat or a press before input
/// opens is dropped (Command W excepted), the band's keys go to the model, and
/// Tab-style keys pass on to SwiftUI.
final class OnboardingKeyPanel: NSPanel {
    /// Whether our app is active. The live one asks `NSApplication`.
    var isActive: () -> Bool = { NSApplication.shared.isActive }
    /// System uptime from which keys and clicks count. The stage passes every
    /// key on at once, because its first Return, Escape or Space skips it.
    var inputOpensAt: () -> TimeInterval = { 0 }
    /// A key, whether it is a repeat, and its timestamp. The model gates it again.
    var onKey: ((OnboardingKey, Bool, TimeInterval) -> Void)?
    /// A click that got through the gate.
    var onClick: (() -> Void)?
    /// The panel took or lost the keyboard.
    var onKeyChange: ((Bool) -> Void)?
    /// True only while a click is making the panel key.
    private var clickMakesKey = false

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

    override var canBecomeKey: Bool { isActive() || clickMakesKey }

    /// Takes the keyboard only if our app is already active. Never activates it.
    func makeKeyIfActive() {
        guard isVisible, alphaValue > 0, !ignoresMouseEvents, isActive() else { return }
        makeKey()
    }

    /// When our app becomes active, setup takes the keyboard only if no other
    /// window of ours holds it (coming back from System Settings, say). If
    /// Settings was just made key, a Return meant for it must not press a
    /// button on the band.
    static func takesKeyboardOnActivation(keyWindow: NSWindow?, ours: [NSWindow]) -> Bool {
        guard let keyWindow else { return true }
        return ours.contains { $0 === keyWindow }
    }

    override func becomeKey() {
        super.becomeKey()
        onKeyChange?(true)
    }

    override func resignKey() {
        super.resignKey()
        onKeyChange?(false)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            let key = OnboardingKey(event, fullKeyboardAccess: NSApplication.shared.isFullKeyboardAccessEnabled)
            onKey?(key, event.isARepeat, event.timestamp)
            // The band's own keys stop here. Tab-style keys reach the focused
            // control once input is open; any other key is dropped.
            if key == .passThrough,
               OnboardingInputGate.allows(key, isRepeat: event.isARepeat, at: event.timestamp, opensAt: inputOpensAt()) {
                super.sendEvent(event)
            }
        case .leftMouseDown:
            guard event.timestamp >= inputOpensAt() else { return }
            onClick?()
            if !isKeyWindow {
                clickMakesKey = true
                makeKey()
                clickMakesKey = false
            }
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }

    /// Command W is a key equivalent, which AppKit offers the key window before
    /// `sendEvent(_:)`. It closes setup and is exempt from the gate.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let key = OnboardingKey(event, fullKeyboardAccess: false)
        guard key == .closeWindow else { return super.performKeyEquivalent(with: event) }
        onKey?(key, event.isARepeat, event.timestamp)
        return true
    }
}

extension OnboardingKey {
    init(_ event: NSEvent, fullKeyboardAccess: Bool) {
        self.init(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags,
            fullKeyboardAccess: fullKeyboardAccess)
    }

    /// Return and keypad Enter, Escape, Left Arrow, Space, Command W; Tab-style
    /// keys pass through. Command W is matched by its character, not its key
    /// code, so it follows the keyboard layout (on AZERTY, W is not key 13).
    init(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags, fullKeyboardAccess: Bool) {
        if modifiers.intersection([.command, .shift, .option, .control]) == .command, characters?.lowercased() == "w" {
            self = .closeWindow
            return
        }
        switch keyCode {
        case 36, 76: self = .returnKey
        case 53: self = .escape
        case 123: self = .leftArrow
        case 48: self = .passThrough
        case 49: self = fullKeyboardAccess ? .passThrough : .space
        default: self = .other
        }
    }
}
