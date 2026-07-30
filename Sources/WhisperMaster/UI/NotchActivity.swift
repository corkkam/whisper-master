import SwiftUI

/// What the notch band is doing right now, as one named value.
///
/// The band's state used to be re-derived at every use site — `isRecording`,
/// `isWorking`, `isFailed`, `shouldShowPolishedBeat`, `preparingEngine != nil` —
/// which is why the orb figure, the state word, and the glow could each disagree
/// about what was happening. Naming the states puts that in one place: resolve
/// once, and the label, the orb, and the light all read from the same value.
///
/// The accent assignment is the system's load-bearing rule (`docs/07-design-system.md`
/// §1), not a palette choice: **ember is the human, signal is the machine.** So
/// listening — your voice, live, in progress — is the only ember state, and every
/// state where the machine is working on or has settled the words is signal. Get
/// this backwards and the band becomes generic dark-mode styling with an accent.
enum NotchActivity: Equatable {
    /// Nothing running. The band is retracted or showing a banner instead.
    case idle
    /// Downloading or loading the engine — the machine getting ready.
    case preparing
    /// Recording. **The one ember state**: this is your voice, live.
    case listening
    /// The key is up and the accurate track is finishing the transcript.
    case transcribing
    /// The optional on-device rewrite is running.
    case polishing
    /// Holding the rewritten line for a beat, so the substitution isn't invisible.
    case polished
    /// The transcript landed in the target app.
    case delivered
    /// The session failed.
    case failed

    /// Resolves the band's state from the app.
    ///
    /// The branch order mirrors `DictationStatusView`'s exactly — download beats a
    /// failure beats the polished beat beats live work beats the delivered beat —
    /// because a mismatch would light the band one colour while it renders another.
    ///
    /// This deliberately does **not** account for the banners (Bluetooth,
    /// undelivered, approval, …). Those own their own chrome and priority in
    /// `DictationPillContent`; this describes the dictation band only, and the
    /// caller passes `.idle` when a banner is what's showing.
    ///
    /// `@MainActor` because `AppState` is: every caller is a SwiftUI view already
    /// on the main actor, and the state it reads is UI state.
    @MainActor
    static func resolve(from state: AppState) -> NotchActivity {
        if state.download != nil { return .preparing }
        if case .failed = state.phase { return .failed }
        if state.shouldShowPolishedBeat, state.polishedText != nil { return .polished }
        if case .recording = state.phase { return .listening }
        if state.isPolishing { return .polishing }
        if state.preparingEngine != nil { return .preparing }
        switch state.phase {
        case .preparingModels, .stopping: return .transcribing
        case .idle, .failed, .recording: break
        }
        if state.shouldShowDeliveredBeat { return .delivered }
        return .idle
    }

    /// The hue this state is lit in. `nil` means the band stays matte black.
    ///
    /// Always the notch sub-palette, never the app-wide tokens: the band sits on
    /// the physical bezel and has no light mode.
    var accent: Color? {
        switch self {
        case .idle: nil
        case .listening: Theme.Notch.accent        // ember — your voice
        case .preparing, .transcribing, .polishing, .polished, .delivered:
            Theme.Notch.success                     // signal — the machine
        case .failed: Theme.Notch.danger
        }
    }

    /// How strongly the state lights the band's edges.
    ///
    /// Listening is the brightest because it is the one state that means *you are
    /// live and being heard*; the machine states are deliberately quieter, so the
    /// band reads as attentive rather than as a light show. Failure is loud enough
    /// to be noticed without shouting.
    ///
    /// These are low numbers on purpose. A saturated hue at low alpha over pure
    /// black stops reading as light and starts reading as dirt — ember in
    /// particular turns brown — so the ceiling here is about the surface staying
    /// convincingly black, not about how visible the state is.
    var glowStrength: Double {
        switch self {
        case .idle: 0
        case .preparing: 0.10
        case .listening: 0.22
        case .transcribing: 0.14
        case .polishing: 0.14
        case .polished: 0.16
        case .delivered: 0.18
        case .failed: 0.20
        }
    }

    /// Where the band's light comes from.
    ///
    /// Light has to belong to something or it reads as a stain. The working states
    /// put the orb at the trailing edge, so that is where their light sits; the
    /// delivered checkmark and the failure line are centred badges with nothing at
    /// the trailing edge, so a glow over there would float in empty space.
    var lightAnchor: UnitPoint {
        switch self {
        case .delivered, .failed: .center
        case .idle, .preparing, .listening, .transcribing, .polishing, .polished: .trailing
        }
    }

    /// Which figure the orb draws, or `nil` for the states that show a glyph
    /// instead (delivered, polished) or nothing at all.
    var orbMode: OrbView.Mode? {
        switch self {
        case .listening: .listening
        case .polishing: .thinking
        case .preparing, .transcribing: .working
        case .idle, .polished, .delivered, .failed: nil
        }
    }

    /// The state in words — the leading edge of the bar before the first word
    /// lands, and the prefix VoiceOver announces the line with.
    ///
    /// `holdToTalk` is needed for one case: in toggle mode the band staying open
    /// isn't explained by a key being held, so it says so.
    func label(holdToTalk: Bool) -> String {
        switch self {
        case .listening: holdToTalk ? "Dictating" : "Dictating (hands-free)"
        case .polishing: "Polishing"
        case .polished: "Polished"
        case .preparing: "Getting ready"
        case .transcribing: "Transcribing"
        case .delivered: "Delivered"
        case .failed: "Failed"
        case .idle: ""
        }
    }
}
