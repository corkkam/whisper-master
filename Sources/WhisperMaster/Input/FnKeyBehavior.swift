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

    // MARK: - Claiming the key

    /// Records that *we* turned the system behaviour off, and what it was before.
    /// Two keys rather than one: "did we do this" has to survive the user setting
    /// the pref back by hand, or we'd silently re-claim the key every launch and
    /// there would be no way for them to keep the emoji picker.
    private static let claimedKey = "WhisperMaster.fnUsage.claimed.v1"
    private static let previousKey = "WhisperMaster.fnUsage.previous.v1"

    /// What the system did with the Globe key before we claimed it, if we did.
    static var claimedPreviousBehavior: FnKeyBehavior? {
        guard UserDefaults.standard.bool(forKey: claimedKey) else { return nil }
        return FnKeyBehavior(rawValue: UserDefaults.standard.integer(forKey: previousKey))
    }

    /// Take the Globe key for push-to-talk: set "Press 🌐 key to: Do Nothing" once,
    /// remembering what it was so it can be handed back.
    ///
    /// **Why this is automatic rather than a prompt.** The key is only claimed when
    /// the user has already chosen fn as their push-to-talk key, and the collision it
    /// removes isn't cosmetic: the hands-free gesture is a *double*-tap, so on a
    /// stock Mac latching hands-free opened and closed the emoji picker on the way,
    /// stealing focus from whatever the dictation was aimed at. Asking permission for
    /// each of those taps is the wrong shape — the choice of key *is* the consent.
    ///
    /// **It happens exactly once.** If the user later puts the emoji picker back, we
    /// leave it: `claimed` stays true, so this returns without touching anything, and
    /// the Settings hint takes over offering the manual fix. Reclaiming on every
    /// launch would be an app overruling a person about their own keyboard.
    ///
    /// - Returns: true if this call is what changed the setting.
    @discardableResult
    static func claimFnKeyForPushToTalk() -> Bool {
        guard !UserDefaults.standard.bool(forKey: claimedKey) else { return false }
        guard let previous = current else {
            // Unset means macOS is applying its own (non-"do nothing") default, so
            // there *is* a conflict — but we don't know which behaviour to hand back.
            // Claim it and record the emoji picker, which is that default.
            UserDefaults.standard.set(true, forKey: claimedKey)
            UserDefaults.standard.set(showEmoji.rawValue, forKey: previousKey)
            return stopSystemFromUsingFnKey()
        }
        guard previous != .doNothing else { return false }
        UserDefaults.standard.set(true, forKey: claimedKey)
        UserDefaults.standard.set(previous.rawValue, forKey: previousKey)
        return stopSystemFromUsingFnKey()
    }

    /// Give the Globe key back to macOS — the undo for `claimFnKeyForPushToTalk`,
    /// offered in Recording settings so a claim we made automatically is always one
    /// click from being reversed.
    ///
    /// - Returns: true if the setting now reads back as the restored behaviour.
    @discardableResult
    static func restoreSystemFnBehavior() -> Bool {
        let previous = claimedPreviousBehavior ?? .showEmoji
        CFPreferencesSetValue(
            defaultsKey,
            previous.rawValue as CFNumber,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("AppleKeyboardPreferencesChangedNotification"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true)
        // Forget the claim either way: the user has asked for the system behaviour
        // back, and leaving the flag set would let a later launch reclaim it.
        UserDefaults.standard.set(false, forKey: claimedKey)
        return current == previous
    }

    /// One line naming what we took, for the settings hint after a claim.
    static var claimDescription: String {
        switch claimedPreviousBehavior {
        case .changeInputSource: "switching your input source"
        case .startDictation: "Apple's own dictation"
        default: "the emoji picker"
        }
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
