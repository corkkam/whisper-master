@testable import WhisperMaster

/// Every onboarding state and every way to render it, for the copy and layout
/// tests to walk.
enum OnboardingCopyCases {
    static let doneRows: [OnboardingDoneRow] = [.movingOn, .waits, .paused]

    /// The download at 100% is the widest the percent can render.
    static let readyVariants: [ReadyVariant] = [
        .ready(assistantLine: true), .ready(assistantLine: false), .typingOff, .micNotAsked, .micDenied,
        .downloading(percent: 100), .preparing, .loadingTypingOff, .loadingMicNotAsked, .loadingMicDenied,
        .failed,
    ]

    static let states: [OnboardingState] = {
        let fixed: [OnboardingState] = [
            .micAsk, .micPromptUp, .micWaiting, .micStillSilent, .micOnVoiceOver, .micDenied, .micFailed,
            .typingAsk, .typingStillOff, .loginAsk, .loginNeedsApproval, .loginFailed,
        ]
        let done = doneRows.flatMap { row -> [OnboardingState] in
            [.micHeard(row), .micOn(row), .typingGranted(row), .loginOn(row)]
        }
        return fixed + done + readyVariants.map { .ready($0) }
    }()

    /// Every key, both forms, the still orb (which changes one body), and Ready
    /// with and without an engine retry (which changes Failed).
    static let copies: [OnboardingCopy] = HotkeyManager.HotkeyOption.allCases.flatMap { key in
        [true, false].flatMap { hold in
            [false, true].flatMap { still in
                [true, false].map { retry in
                    OnboardingCopy(key: key, holdToTalk: hold, orbIsStatic: still, canRetryEngine: retry)
                }
            }
        }
    }

    /// Every top-bar context the rules distinguish.
    static let topBarContexts: [OnboardingTopBarContext] = {
        var contexts: [OnboardingTopBarContext] = []
        for step in NotchOnboardingStep.allCases {
            for key in [false, true] {
                for nudging in [false, true] {
                    for paused in [false, true] {
                        let variants: [ReadyVariant?] = step == .ready ? readyVariants : [nil]
                        for variant in variants {
                            for mic in [ReadyMicStatus.notAsked, .denied, .on] {
                                contexts.append(OnboardingTopBarContext(
                                    step: step, readyVariant: variant, readyMic: mic, nudging: nudging,
                                    micCheckListening: false, pausedWhileInactive: paused, panelIsKey: key))
                            }
                        }
                    }
                }
            }
        }
        return contexts
    }()

    /// Every string a copy renders, with where it came from.
    static func allStrings(_ copy: OnboardingCopy) -> [(source: String, text: String)] {
        var out: [(String, String)] = []
        for state in states {
            let screen = copy.screen(state)
            out.append(("\(state) headline", screen.headline))
            out.append(("\(state) body", screen.body))
            if let fallback = screen.fallbackBody { out.append(("\(state) fallback", fallback)) }
            if case .badge(let badge, _) = screen.row { out.append(("\(state) badge", badge)) }
            for button in OnboardingButton.allCases {
                if let hint = copy.hint(for: button, in: state) { out.append(("\(state) \(button) hint", hint)) }
            }
        }
        for context in topBarContexts {
            if let line = copy.topBarLine(context) {
                out.append(("top bar \(context)", line.text))
                if let fallback = line.fallback, !fallback.isEmpty { out.append(("top bar fallback", fallback)) }
            }
        }
        out.append(("ready notice on", copy.readyNotice(typingOn: true)))
        out.append(("ready notice off", copy.readyNotice(typingOn: false)))
        for step in NotchOnboardingStep.allCases { out.append(("band label", OnboardingCopy.bandLabel(step))) }
        let fixed = [
            OnboardingCopy.wordmark, OnboardingCopy.tagline, OnboardingCopy.backLabel, OnboardingCopy.backTooltip,
            OnboardingCopy.backAccessibilityLabel, OnboardingCopy.settingsLabel, OnboardingCopy.closeTooltip,
            OnboardingCopy.closeAccessibilityLabel, OnboardingCopy.stepProgressLabel, OnboardingCopy.waitingLine,
            OnboardingCopy.movingOnLine.text, OnboardingCopy.movingOnLine.fallback ?? "",
            OnboardingCopy.pausedLine.text, OnboardingCopy.firstAnnouncement, OnboardingCopy.inactiveAnnouncement,
        ] + OnboardingButton.allCases.map(\.title)
        out += fixed.map { ("fixed", $0) }
        return out
    }
}
