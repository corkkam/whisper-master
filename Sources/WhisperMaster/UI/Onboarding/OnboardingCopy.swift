import Foundation

// Every word onboarding says, in one place, so the fit tests can measure each
// one for every push-to-talk key and both forms. The copy is the app speaking:
// first person, plain words, one idea per sentence, no semicolons.
//
// Hints that name Return, Escape, Left Arrow or Command W ship with the key
// panel, because a hint must never name a key the band does not answer yet.
// Until then each such string shows only its part without the key.

/// One of the three forms a push-to-talk key name takes in a sentence.
enum OnboardingKeyForm {
    /// `{key}`: "the right Option key".
    case name
    /// `{key:first}`: the first-use form, which also says where the key is.
    case first
    /// `{key:first}` with the location after the comma left out.
    case firstWithoutLocation
    /// `{key:cap}`: for the start of a sentence.
    case cap
}

/// The buttons the band can show. The raw value is the visible title.
enum OnboardingButton: String, CaseIterable {
    case allowMicrophone = "Allow Microphone"
    case allowTyping = "Allow Typing"
    case startWithMac = "Start with your Mac"
    case openLoginItems = "Open Login Items"
    case openSystemSettings = "Open System Settings"
    case tryAgain = "Try Again"
    case notNow = "Not now"
    case done = "Done"
    case closeAndOpenSettings = "Close and open Settings"
    case `continue` = "Continue"

    var title: String { rawValue }
}

/// How a done step's row ends. A done step moves on by itself or waits, never both.
enum OnboardingDoneRow: Hashable {
    /// The badge and the moving-on line, no button.
    case movingOn
    /// The badge and Continue: after Back, or while VoiceOver or Switch Control is on.
    case waits
    /// The badge, the paused line and Continue: the app is not active.
    case paused
}

/// The action row under the copy.
enum OnboardingRow: Equatable {
    /// One or two buttons, the main one first.
    case buttons([OnboardingButton])
    /// The system prompt is up: the waiting line and Not now.
    case waiting
    /// A done step: the badge's text, which is also its VoiceOver label.
    case badge(String, OnboardingDoneRow)

    var buttons: [OnboardingButton] {
        switch self {
        case .buttons(let buttons): return buttons
        case .waiting: return [.notNow]
        case .badge(_, .movingOn): return []
        case .badge: return [.continue]
        }
    }
}

/// One line of copy and the shorter one the band shows when it does not fit.
struct OnboardingLine: Equatable {
    var text: String
    /// `nil`: no fallback. Empty: the line drops when it does not fit.
    var fallback: String?

    init(_ text: String, fallback: String? = nil) {
        self.text = text
        self.fallback = fallback
    }
}

/// What one state of the band says.
struct OnboardingScreen: Equatable {
    var headline: String
    var body: String
    /// The shorter body the band shows when `body` does not fit two lines.
    var fallbackBody: String? = nil
    var row: OnboardingRow
}

/// Every state the band can be in, beat by beat.
enum OnboardingState: Hashable {
    // Beat 1: Microphone
    case micAsk
    /// The system's microphone prompt is up.
    case micPromptUp
    /// Allowed in this flow, waiting for a voice.
    case micWaiting
    /// About 8 s of silence after the waiting copy showed.
    case micStillSilent
    /// The mic check heard a voice.
    case micHeard(OnboardingDoneRow)
    /// Allowed before this flow, no voice heard yet (also after Back).
    case micOn(OnboardingDoneRow)
    /// Allowed, with VoiceOver on: no mic check runs, so it waits for Continue.
    case micOnVoiceOver
    case micDenied
    /// The mic check could not start.
    case micFailed
    // Beat 2: Typing
    case typingAsk
    /// Asked, back from System Settings, and still not trusted.
    case typingStillOff
    case typingGranted(OnboardingDoneRow)
    // Beat 3: Start with your Mac
    case loginAsk
    /// Registered, but macOS holds it for approval in Login Items.
    case loginNeedsApproval
    case loginOn(OnboardingDoneRow)
    case loginFailed
    // Beat 4: Ready
    case ready(ReadyVariant)

    var step: NotchOnboardingStep {
        switch self {
        case .micAsk, .micPromptUp, .micWaiting, .micStillSilent, .micHeard, .micOn, .micOnVoiceOver,
             .micDenied, .micFailed:
            return .microphone
        case .typingAsk, .typingStillOff, .typingGranted:
            return .accessibility
        case .loginAsk, .loginNeedsApproval, .loginOn, .loginFailed:
            return .openAtLogin
        case .ready:
            return .ready
        }
    }
}

/// The last beat, from the engine, the microphone and typing. No variant says
/// "You're ready" unless the engine is ready and the microphone is on. The
/// microphone outranks typing: without it nothing works, while typing off
/// still reaches the clipboard.
enum ReadyVariant: Hashable {
    case ready(assistantLine: Bool)
    case typingOff
    case micNotAsked
    case micDenied
    case downloading(percent: Int)
    case preparing
    case loadingTypingOff
    case loadingMicNotAsked
    case loadingMicDenied
    case failed

    /// `showsAssistantLine`: the assistant chord is available and at least one
    /// connector exists. False on a first launch.
    static func resolve(
        engine: EngineStatus, mic: ReadyMicStatus, typingOn: Bool, showsAssistantLine: Bool
    ) -> ReadyVariant {
        switch engine {
        case .failed:
            return .failed
        case .ready:
            switch mic {
            case .notAsked: return .micNotAsked
            case .denied: return .micDenied
            case .on: return typingOn ? .ready(assistantLine: showsAssistantLine) : .typingOff
            }
        case .downloading(let percent):
            switch mic {
            case .notAsked: return .loadingMicNotAsked
            case .denied: return .loadingMicDenied
            case .on: return typingOn ? .downloading(percent: percent) : .loadingTypingOff
            }
        case .preparing:
            switch mic {
            case .notAsked: return .loadingMicNotAsked
            case .denied: return .loadingMicDenied
            case .on: return typingOn ? .preparing : .loadingTypingOff
            }
        }
    }

    /// The two variants that say "You're ready" and invite the user to hold the key.
    var invitesHold: Bool {
        switch self {
        case .ready, .typingOff: return true
        default: return false
        }
    }
}

/// What the top-bar line reads from. At most one line shows: the first rule
/// that applies.
struct OnboardingTopBarContext: Equatable {
    var step: NotchOnboardingStep
    /// Ready only.
    var readyVariant: ReadyVariant? = nil
    var readyMic: ReadyMicStatus = .on
    /// Within 4 s of a capture key press that setup ignored.
    var nudging = false
    var micCheckListening = false
    /// A done step shows Continue because the app is not active.
    var pausedWhileInactive = false
    var panelIsKey = false
}

/// Renders the copy for one push-to-talk key and one form.
struct OnboardingCopy {
    /// Always the push-to-talk key the user chose in Settings.
    var key: HotkeyManager.HotkeyOption = .fn
    /// "Hold to talk" on (the default): the hold form. Off: the press form.
    var holdToTalk = true
    /// System Reduce Motion stills the orb, so the waiting body cannot say the
    /// dots move.
    var orbIsStatic = false

    // MARK: Fixed lines

    static let wordmark = "Whisper Master"
    static let tagline = "Talk, and I'll type it."
    /// The assistant chord is fixed, so this line always names it.
    static let chordLine = "To ask about your day, hold the fn key and Control."

    static let backLabel = "Back"
    static let backTooltip = "Go back"
    static let backAccessibilityLabel = "Go back"
    static let settingsLabel = "Open Whisper Master Settings"
    static let closeTooltip = "Close setup"
    static let closeAccessibilityLabel = "Close setup"
    static let stepProgressLabel = "Setup steps"
    static let waitingLine = "Waiting for your answer…"
    static let movingOnLine = OnboardingLine("Next step in a moment.", fallback: "Next step soon.")
    static let pausedLine = OnboardingLine("Continue goes to the next step.", fallback: "")

    /// The two VoiceOver announcements, and the only two.
    static let firstAnnouncement = "Whisper Master setup. Talk, and I'll type it. Your voice stays on this Mac."
    static let inactiveAnnouncement = "Whisper Master setup is waiting. Switch to Whisper Master to continue."

    // MARK: Key names

    static func key(_ key: HotkeyManager.HotkeyOption, form: OnboardingKeyForm) -> String {
        let name: String
        let first: String
        switch key {
        case .fn:
            name = "the fn key"
            first = "the fn key (the key with a globe symbol), at the bottom left of most Mac keyboards"
        case .rightOption:
            name = "the right Option key"
            first = "the right Option key, to the right of the space bar"
        case .leftOption:
            name = "the left Option key"
            first = "the left Option key, to the left of the space bar"
        case .rightCommand:
            name = "the right Command key"
            first = "the right Command key, just right of the space bar"
        }
        switch form {
        case .name: return name
        case .first: return first
        case .firstWithoutLocation: return String(first.prefix { $0 != "," })
        case .cap: return name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    private var keyName: String { Self.key(key, form: .name) }

    // MARK: Screens

    func screen(_ state: OnboardingState) -> OnboardingScreen {
        switch state {
        case .micAsk:
            let ask = micAskBody
            return OnboardingScreen(
                headline: "Let's start with your voice.", body: ask.text, fallbackBody: ask.fallback,
                row: .buttons([.allowMicrophone, .notNow]))
        case .micPromptUp:
            let ask = micAskBody
            return OnboardingScreen(
                headline: "Let's start with your voice.", body: ask.text, fallbackBody: ask.fallback, row: .waiting)
        case .micWaiting:
            let lead = holdToTalk
                ? "Hold \(keyName) and say anything."
                : "Press \(keyName), say anything, and press it again."
            let tail = orbIsStatic ? "I'll tell you when I hear you." : "The dots move with your voice."
            return OnboardingScreen(headline: "Now say hello.", body: "\(lead) \(tail)", row: .buttons([.notNow]))
        case .micStillSilent:
            let keyLine = holdToTalk ? "Hold \(keyName) while you speak." : "Press \(keyName) before you speak."
            return OnboardingScreen(
                headline: "Now say hello.",
                body: "Check that your microphone is on in System Settings. \(keyLine)",
                fallbackBody: "Check your microphone in System Settings. \(keyLine)",
                row: .buttons([.openSystemSettings, .notNow]))
        case .micHeard(let row):
            return OnboardingScreen(
                headline: "There you are.", body: "I heard you. Your voice stays on this Mac.",
                row: .badge("Heard you", row))
        case .micOn(let row):
            return OnboardingScreen(
                headline: "Your microphone is on.", body: "You allowed it before, so this step is done.",
                row: .badge("Microphone on", row))
        case .micOnVoiceOver:
            let body = holdToTalk
                ? "I listen only while you hold \(keyName)."
                : "I listen only between two presses of \(keyName)."
            return OnboardingScreen(
                headline: "Your microphone is on.", body: body, row: .badge("Microphone on", .waits))
        case .micDenied:
            return OnboardingScreen(
                headline: "I can't hear you yet.",
                body: "The microphone is off for Whisper Master. Turn it on in System Settings.",
                row: .buttons([.openSystemSettings, .notNow]))
        case .micFailed:
            return OnboardingScreen(
                headline: "I can't reach your microphone.",
                body: "Check that a microphone is connected, then try again.",
                row: .buttons([.tryAgain, .notNow]))

        case .typingAsk:
            let lead = "So I can type for you in other apps, I need one switch in System Settings. I'll open it."
            return OnboardingScreen(
                headline: "Next, let me type for you.", body: "\(lead) If you skip, I copy your words.",
                fallbackBody: lead, row: .buttons([.allowTyping, .notNow]))
        case .typingStillOff:
            return OnboardingScreen(
                headline: "Typing is still off.",
                body: "Turn on Whisper Master on the \"Accessibility\" page. Until then, I copy your words for you to paste.",
                row: .buttons([.openSystemSettings, .notNow]))
        case .typingGranted(let row):
            return OnboardingScreen(
                headline: "Now I can type for you.", body: "Your words will land where you want to type.",
                row: .badge("Allowed", row))

        case .loginAsk:
            return OnboardingScreen(
                headline: "Want me ready after a restart?",
                body: "If I start with your Mac, I'm ready the moment you log in.",
                row: .buttons([.startWithMac, .notNow]))
        case .loginNeedsApproval:
            return OnboardingScreen(
                headline: "One more switch, in Settings.",
                body: "Turn on Whisper Master under Login Items, then come back here.",
                row: .buttons([.openLoginItems, .notNow]))
        case .loginOn(let row):
            return OnboardingScreen(
                headline: "I'll be ready after a restart.", body: "I'll start each time you log in to your Mac.",
                row: .badge("Turned on", row))
        case .loginFailed:
            // Never the raw error: that goes to the log only.
            return OnboardingScreen(
                headline: "I couldn't set that up.", body: "You can turn it on later in Settings.",
                row: .buttons([.tryAgain, .notNow]))

        case .ready(let variant):
            return ready(variant)
        }
    }

    /// The Microphone ask, which Ready's "Microphone not asked" repeats.
    private var micAskBody: OnboardingLine {
        let lead = holdToTalk ? "I listen only while you hold" : "I listen only between two presses of"
        return OnboardingLine(
            "\(lead) \(Self.key(key, form: .first)).",
            fallback: "\(lead) \(Self.key(key, form: .firstWithoutLocation)).")
    }

    private func ready(_ variant: ReadyVariant) -> OnboardingScreen {
        let loading = "You can talk once I'm ready."
        let early = holdToTalk ? "Holding \(keyName) early" : "Pressing \(keyName) early"
        switch variant {
        case .ready(let assistantLine):
            let short = holdToTalk
                ? "Click where you want to type. Then hold \(keyName) and talk."
                : "Click where you want to type. Then press \(keyName) and talk."
            let full = holdToTalk
                ? "Click where you want to type. Then hold \(keyName) and talk"
                : "Click where you want to type. Then press \(keyName), talk, and press it again"
            let body: String
            if assistantLine {
                body = "\(full). \(Self.chordLine)"
            } else {
                body = holdToTalk ? "\(full), and I'll type it." : "\(full)."
            }
            return OnboardingScreen(
                headline: "You're ready. Try it now.", body: body, fallbackBody: short, row: .buttons([.done]))
        case .typingOff:
            let lead = holdToTalk
                ? "Hold \(keyName) and talk."
                : "Press \(keyName), talk, and press it again."
            let short = holdToTalk ? "Hold \(keyName) and talk." : "Press \(keyName) and talk."
            return OnboardingScreen(
                headline: "You're ready. Typing is off.",
                body: "\(lead) I'll copy your words instead. Paste them with Command V.",
                fallbackBody: "\(short) I'll copy your words for you to paste.",
                row: .buttons([.openSystemSettings, .done]))
        case .micNotAsked:
            let ask = micAskBody
            return OnboardingScreen(
                headline: "One thing left: your microphone.", body: ask.text, fallbackBody: ask.fallback,
                row: .buttons([.allowMicrophone, .done]))
        case .micDenied:
            return OnboardingScreen(
                headline: "Your microphone is still off.",
                body: "I can't hear you until you turn it on in System Settings.",
                row: .buttons([.openSystemSettings, .done]))
        case .downloading(let percent):
            return OnboardingScreen(
                headline: loading,
                body: "I'm downloading speech files (\(percent)%). The download keeps going. \(early) only shows my progress.",
                fallbackBody: "Downloading (\(percent)%). The download keeps going. \(early) shows progress.",
                row: .buttons([.closeAndOpenSettings, .done]))
        case .preparing:
            return OnboardingScreen(
                headline: loading,
                body: "I'm loading speech files. Loading keeps going. \(early) only shows my progress.",
                fallbackBody: "Loading keeps going. \(early) shows progress.",
                row: .buttons([.closeAndOpenSettings, .done]))
        case .loadingTypingOff:
            return OnboardingScreen(
                headline: loading, body: "Typing is off. I'll copy your words instead.",
                row: .buttons([.openSystemSettings, .done]))
        case .loadingMicNotAsked:
            return OnboardingScreen(
                headline: loading, body: "I also need your microphone. You can allow it while I load.",
                row: .buttons([.allowMicrophone, .done]))
        case .loadingMicDenied:
            return OnboardingScreen(
                headline: loading, body: "The microphone is off. Turn it on in System Settings while I load.",
                row: .buttons([.openSystemSettings, .done]))
        case .failed:
            // No mention of Settings: it has no engine Try Again. Done starts one
            // more background attempt.
            return OnboardingScreen(
                headline: "I couldn't finish getting ready.",
                body: "Check your internet, then press Try Again. Or press Done, and I'll try once more in the background.",
                fallbackBody: "Check your internet, then press Try Again.",
                row: .buttons([.tryAgain, .done]))
        }
    }

    // MARK: Hints

    /// A button's VoiceOver hint. The main button has none, except Close and
    /// open Settings, which says the work keeps going.
    func hint(for button: OnboardingButton, in state: OnboardingState) -> String? {
        switch button {
        case .notNow:
            return "Skips this step."
        case .done:
            if case .ready(let variant) = state, variant.invitesHold {
                let verb = holdToTalk ? "hold" : "press"
                return "Closes setup. Then click where you want to type, and \(verb) \(keyName)."
            }
            return "Closes setup."
        case .closeAndOpenSettings:
            if case .ready(.preparing) = state { return "Closes setup and opens Settings. Loading keeps going." }
            return "Closes setup and opens Settings. The download keeps going."
        default:
            return nil
        }
    }

    // MARK: Top-bar line

    func topBarLine(_ context: OnboardingTopBarContext) -> OnboardingLine? {
        let early = context.step != .ready
        // 1. The nudge after an ignored capture key press. Never while the mic
        // check listens: its own copy already says to hold the key.
        if context.nudging, !context.micCheckListening {
            if early {
                // The keyboard form names Command W, which ships with the key panel.
                if context.panelIsKey { return OnboardingLine("Finish setup first.") }
                return OnboardingLine(
                    "Finish setup first, or click here to use the keyboard.", fallback: "Finish setup first.")
            }
            switch context.readyMic {
            case .notAsked: return OnboardingLine("Allow the microphone first.")
            case .denied: return OnboardingLine("Turn on the microphone first.")
            case .on: break
            }
        }
        // 2. A done step waits because the app is not active.
        if context.pausedWhileInactive {
            return OnboardingLine("Switch back to Whisper Master to go on.")
        }
        // 3. The band does not have the keyboard.
        if !context.panelIsKey {
            if early { return OnboardingLine("Click here to use the keyboard.") }
            guard context.readyVariant?.invitesHold == true else { return nil }
            // No fallback: the full key name stays. The press form drops "Now"
            // so the longest key name still fits the line.
            return OnboardingLine(holdToTalk ? "Now hold \(keyName) and talk." : "Press \(keyName) and talk.")
        }
        // 4. "Command W closes setup." ships with the key panel.
        return nil
    }

    // MARK: Step progress and VoiceOver

    /// A step is done when its permission or setting is on. One predicate for
    /// both the past capsule's colour and its VoiceOver word: a microphone that
    /// is on, whose voice test was skipped, is done.
    static func stepIsDone(_ step: NotchOnboardingStep, micOn: Bool, typingOn: Bool, loginOn: Bool) -> Bool {
        switch step {
        case .microphone: return micOn
        case .accessibility: return typingOn
        case .openAtLogin: return loginOn
        case .ready: return false
        }
    }

    /// "Step 3 of 4, Start with your Mac. Microphone done, Typing skipped."
    static func stepProgressValue(
        current: NotchOnboardingStep, micOn: Bool, typingOn: Bool, loginOn: Bool
    ) -> String {
        let count = NotchOnboardingStep.allCases.count
        let head = "Step \(current.rawValue + 1) of \(count), \(current.title)."
        let past = NotchOnboardingStep.allCases.filter { $0.rawValue < current.rawValue }.map { step in
            let done = stepIsDone(step, micOn: micOn, typingOn: typingOn, loginOn: loginOn)
            return "\(step.title) \(done ? "done" : "skipped")"
        }
        return past.isEmpty ? head : "\(head) \(past.joined(separator: ", "))."
    }

    static func bandLabel(_ step: NotchOnboardingStep) -> String {
        "Setup, step \(step.rawValue + 1) of \(NotchOnboardingStep.allCases.count): \(step.title)"
    }

    // MARK: Ready notice

    /// The one line at the notch once the speech files finish loading after setup.
    func readyNotice(typingOn: Bool) -> String {
        guard typingOn else { return "I'm ready. Typing is off, so I'll copy your words." }
        return holdToTalk ? "I'm ready. Hold \(keyName) and talk." : "I'm ready. Press \(keyName) and talk."
    }
}
