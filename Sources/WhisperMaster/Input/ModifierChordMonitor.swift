import AppKit

/// A held *combination* of modifier keys — as opposed to `HotkeyManager`'s single
/// key. Used for the "say a command" push-to-talk (fn + control).
///
/// A chord can't be recognised the way `HotkeyManager` recognises its key (match
/// the key code that changed, then read that key's own bit): either half of the
/// chord can be the key that moved, and the other half's state only shows up in
/// the event's full modifier mask. So a chord is evaluated from the whole mask,
/// which has the happy side effect of being side-agnostic — whichever control key
/// is nearer counts.
struct ModifierChord: Equatable, Sendable {
    /// Every mask here must be present in the event's flags for the chord to be
    /// held. Deliberately the *generic* flags (`.function`, `.control`) rather than
    /// the device-dependent left/right bits `HotkeyOption` uses.
    let masks: [UInt]
    /// Key-cap style label for Settings, e.g. "🌐 FN + ⌃ CTRL".
    let compactName: String
    /// Prose name for copy and VoiceOver.
    let displayName: String

    /// **fn + control** — "what I'm about to say goes to the assistant, not to the
    /// cursor". The single entry point for every agent action and connector
    /// conversation: notes, reminders, calendar reads, connector writes, questions.
    /// Fixed rather than user-configurable: it layers on top of whatever the
    /// push-to-talk key is (and with the default `fn` dictation key it reads as
    /// exactly that — dictation plus control).
    ///
    /// It is also the *only* way in. Nothing infers assistant intent from the words
    /// of an unarmed dictation, because the assistant path suppresses the paste and a
    /// wrong guess therefore eats the transcript.
    static let command = ModifierChord(
        masks: [
            NSEvent.ModifierFlags.function.rawValue,
            NSEvent.ModifierFlags.control.rawValue,
        ],
        compactName: "🌐 FN + ⌃ CTRL",
        displayName: "Globe / fn (🌐) + Control (⌃)")

    func isHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        masks.allSatisfy { flags.rawValue & $0 != 0 }
    }
}

/// Watches for a `ModifierChord` being held and released, on the same
/// local + global `.flagsChanged` monitors `HotkeyManager` uses.
///
/// It reports only the two *edges* — the chord becoming complete and the chord
/// breaking — and takes no view on what they mean; the view model decides whether
/// an edge starts a recording or re-labels the one already running.
@MainActor
final class ModifierChordMonitor {
    enum Event {
        /// Every key of the chord is now held.
        case engaged
        /// The chord was complete and no longer is (either key came up).
        case released
    }

    private let chord: ModifierChord
    private let onEvent: (Event) -> Void
    private var isHeld = false
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(chord: ModifierChord, onEvent: @escaping (Event) -> Void) {
        self.chord = chord
        self.onEvent = onEvent
        install()
    }

    deinit {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    private func install() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        let held = chord.isHeld(event.modifierFlags)
        guard held != isHeld else { return }
        isHeld = held
        onEvent(held ? .engaged : .released)
    }
}
