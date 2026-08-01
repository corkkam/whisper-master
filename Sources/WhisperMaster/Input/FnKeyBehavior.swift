import AppKit

/// What macOS itself does when the Globe/**fn** key is pressed.
///
/// The fn key is the best push-to-talk key on a MacBook — it's under your thumb
/// and no app binds it mid-sentence — but the system may already claim it (emoji
/// picker, input-source switch, or Apple's own dictation on a double-press). Our
/// monitors are *passive* observers of `flagsChanged`: they see the key without
/// consuming it, so a system action fires alongside ours. Swallowing the event
/// would need a HID-level tap that also breaks fn+F-key and fn+arrow behaviour,
/// which isn't worth it — so instead we detect the collision and say so.
///
/// The preference lives in `NSGlobalDomain` as `AppleFnUsageType`. It is read and
/// written through `CFPreferences` against `kCFPreferencesAnyApplication` rather
/// than `UserDefaults.standard`: standard *reads* fall through to the global domain
/// but standard *writes* land in our own app domain, where nothing would ever look
/// for them, and its cached reads wouldn't reflect our own write.
enum FnKeyBehavior: Int {
    case doNothing = 0
    case changeInputSource = 1
    case showEmoji = 2
    case startDictation = 3

    private static let defaultsKey = "AppleFnUsageType" as CFString

    /// The system's current setting. An absent key means macOS is applying its own
    /// default, which is *not* "do nothing" on any Mac with a Globe key — so treat
    /// unset as a live conflict rather than quietly assuming we're in the clear.
    static var current: FnKeyBehavior? {
        let value = CFPreferencesCopyValue(
            defaultsKey,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
        guard let raw = value as? Int else { return nil }
        return FnKeyBehavior(rawValue: raw)
    }

    /// Sets "Press 🌐 key to: Do Nothing" so the key belongs to push-to-talk alone —
    /// the one-tap version of the trip through System Settings that the hint offers
    /// beside it.
    ///
    /// This is the *only* thing that stops the emoji picker from firing on a fn tap
    /// (and so from firing twice on the hands-free double-tap). Our monitors are
    /// passive observers of `flagsChanged` and cannot swallow the key; consuming it
    /// would take a HID-level `CGEventTap` that also breaks fn+F-key and fn+arrow.
    ///
    /// Writing another app's domain needs the app to be **un-sandboxed** (it is) and
    /// still can't be verified from the write itself — `CFPreferencesSynchronize`
    /// reports the flush, not whether the input-method agent has picked the value up
    /// — so the caller re-reads `current` and reports what it actually sees.
    /// - Returns: true if the setting now reads back as `.doNothing`.
    @discardableResult
    static func stopSystemFromUsingFnKey() -> Bool {
        CFPreferencesSetValue(
            defaultsKey,
            doNothing.rawValue as CFNumber,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
        // The agents that own the Globe key (HIToolbox / the text-input menu) read
        // this on a global-preferences change, so nudge them rather than making the
        // user log out. Best-effort: no reply, and no way to confirm delivery.
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("AppleKeyboardPreferencesChangedNotification"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true)
        return current == .doNothing
    }

    /// True when pressing fn will also do something of the system's own.
    static var conflictsWithPushToTalk: Bool {
        current != .doNothing
    }

    /// One line naming what else the key currently does, for the settings hint.
    static var conflictDescription: String {
        switch current {
        case .changeInputSource: "it also switches your input source"
        case .showEmoji: "it also opens the emoji picker"
        case .startDictation: "it also starts Apple's dictation"
        case .doNothing: ""
        case nil: "macOS may also act on it"
        }
    }

    /// Opens System Settings on the Keyboard pane, where "Press 🌐 key to" lives.
    static func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
