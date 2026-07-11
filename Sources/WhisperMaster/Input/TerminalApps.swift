import AppKit
import Carbon.HIToolbox

/// Terminal emulators are the one paste target that always has a real
/// destination (the shell prompt) yet doesn't advertise it through
/// Accessibility the way a native `NSTextView` does:
///
///  - GPU/custom-rendered terminals (Ghostty, Warp, Alacritty, kitty, WezTerm)
///    expose **no** settable value, text role, or caret (`kAXSelectedTextRange`),
///    so `FocusedElementInspector.focusHasNoTextTarget()` mistakes them for a
///    "nowhere to type" surface and the transcript is copied but never pasted.
///  - AppKit terminals (Terminal.app, iTerm2) report `AXTextArea`, so they take
///    the per-character `keyboardSetUnicodeString` inject path — which terminals
///    routinely drop (they key off virtual keycodes, not synthesized Unicode).
///
/// Both classes honor a real ⌘V, so `pasteFinal` routes any frontmost terminal
/// through the clipboard/⌘V path instead. Identity is the bundle id (an explicit
/// allow-list — safe, no false positives — extend it as new terminals appear).
enum TerminalApps {
    /// Known terminal-emulator bundle identifiers.
    static let bundleIDs: Set<String> = [
        "com.apple.Terminal",          // Terminal.app
        "com.googlecode.iterm2",       // iTerm2
        "com.mitchellh.ghostty",       // Ghostty
        "dev.warp.Warp-Stable",        // Warp
        "dev.warp.Warp-Preview",       // Warp (preview channel)
        "org.alacritty",               // Alacritty
        "net.kovidgoyal.kitty",        // kitty
        "com.github.wez.wezterm",      // WezTerm
        "co.zeit.hyper",               // Hyper
        "org.tabby",                   // Tabby
        "com.raphamorim.rio",          // Rio
    ]

    /// Whether a bundle id names a known terminal emulator. Pure — unit-tested.
    static func isTerminal(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }

    /// Whether the app about to receive the paste (the frontmost app — we never
    /// steal focus) is a terminal emulator.
    static func frontmostIsTerminal() -> Bool {
        isTerminal(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// True when macOS **Secure Keyboard Entry** is active anywhere. While it is,
    /// the WindowServer drops *all* synthesized `CGEvent`s from other processes —
    /// so neither per-character injection nor ⌘V can reach the target. Terminal.app
    /// has an explicit "Secure Keyboard Entry" menu item; this is the classic cause
    /// of "paste works everywhere but the terminal." Read-only, so callers can
    /// surface a clear hint instead of failing silently.
    static func secureKeyboardEntryEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }
}
