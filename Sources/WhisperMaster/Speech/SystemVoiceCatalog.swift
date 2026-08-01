import AVFoundation
import AppKit

/// The installed macOS voices worth offering, and the rules for picking one.
///
/// A stock Mac reports **well over a hundred** voices from
/// `AVSpeechSynthesisVoice.speechVoices()` — most of them other locales, and a long tail
/// of novelty voices (Bells, Bubbles, Zarvox, Bad News). Dropped into a picker unfiltered
/// that list is unusable, so this narrows it to voices someone would actually want to
/// hear an answer in.
enum SystemVoiceCatalog {

    /// One offerable voice. `id` is the `AVSpeechSynthesisVoice.identifier`; the empty
    /// string is the **Automatic** choice, resolved fresh each time (see `resolve`).
    struct Choice: Identifiable, Hashable {
        let id: String
        let name: String
        let quality: AVSpeechSynthesisVoiceQuality

        /// "Ava (Premium)" — the same shape macOS uses in Spoken Content, so the
        /// picker and System Settings agree about what a voice is called.
        var label: String {
            switch quality {
            case .premium: return "\(name) (Premium)"
            case .enhanced: return "\(name) (Enhanced)"
            default: return name
            }
        }
    }

    /// The Automatic entry. Deliberately first and deliberately the default: it
    /// re-resolves to the best installed voice every time, so the day the user
    /// downloads a Premium voice the app starts using it with no setting to change.
    static let automatic = Choice(id: "", name: "Automatic", quality: .default)

    // MARK: - Enumeration

    /// Offerable voices, best quality first, with `automatic` at the head.
    ///
    /// Cached — `speechVoices()` walks every installed voice, and this is read from a
    /// SwiftUI `body`. `invalidate()` (wired to the system's own change notification)
    /// is what keeps the cache honest.
    static func installed(selecting selectedID: String? = nil) -> [Choice] {
        var choices = catalog().choices
        // A deliberate choice must never vanish from its own menu because it failed a
        // filter (a novelty voice picked on purpose, or one for another language).
        if let selectedID, !selectedID.isEmpty, !choices.contains(where: { $0.id == selectedID }),
           let voice = AVSpeechSynthesisVoice(identifier: selectedID) {
            choices.insert(
                Choice(id: voice.identifier, name: voice.name, quality: voice.quality),
                at: 1)
        }
        return choices
    }

    /// Enumerating voices walks well over a hundred entries, and both `installed` and
    /// `resolvedVoiceIsBasic` are read from a SwiftUI `body` — so the list *and* the
    /// resolved best voice are computed together and cached together.
    private static var cached: (choices: [Choice], best: AVSpeechSynthesisVoice?)?

    private static func catalog() -> (choices: [Choice], best: AVSpeechSynthesisVoice?) {
        if let cached { return cached }
        let built = build()
        cached = built
        return built
    }

    /// macOS posts this when a voice finishes downloading. Observing it is what makes
    /// the "go install a better voice" nudge feel like it worked — the picker gains the
    /// new voice and the nudge disappears without a relaunch. Idempotent; called from
    /// the Settings row that shows the picker.
    static func startObservingVoiceChanges() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            cached = nil
        }
    }

    private static var observer: NSObjectProtocol?

    static func invalidate() { cached = nil }

    private static func build() -> (choices: [Choice], best: AVSpeechSynthesisVoice?) {
        let wanted = primaryLanguage(of: AVSpeechSynthesisVoice.currentLanguageCode())
        let usable = AVSpeechSynthesisVoice.speechVoices().filter(isUsable)
        var matching = usable.filter { primaryLanguage(of: $0.language) == wanted }
        // Better an unfiltered list than an empty picker if the language match fails.
        if matching.isEmpty { matching = usable }
        let sorted = matching.sorted {
            $0.quality == $1.quality
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.quality.rank > $1.quality.rank
        }
        let choices = [automatic] + sorted.map {
            Choice(id: $0.identifier, name: $0.name, quality: $0.quality)
        }

        // "Automatic" prefers the user's *exact* locale before falling back to any
        // dialect of the same language — an en-GB premium voice reading en-US dates is
        // a worse default than an en-US enhanced one.
        let exact = sorted.filter { $0.language == AVSpeechSynthesisVoice.currentLanguageCode() }
        let best = exact.first
            ?? sorted.first
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        return (choices, best)
    }

    /// Novelty voices are a joke, personal voices belong to their owner, and Siri's
    /// voices aren't licensed to third-party apps — one selected by accident
    /// synthesizes silence, which reads as the feature being broken.
    private static func isUsable(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if voice.voiceTraits.contains(.isNoveltyVoice) { return false }
        if voice.voiceTraits.contains(.isPersonalVoice) { return false }
        if voice.identifier.contains(".siri_") { return false }
        return true
    }

    /// "en-GB" and "en_US" both reduce to "en", so a UK user still sees Ava alongside
    /// Daniel rather than a picker with one entry in it.
    private static func primaryLanguage(of code: String) -> String {
        code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased()
            ?? code.lowercased()
    }

    // MARK: - Resolution

    /// The voice to actually speak with, or `nil` to let the synthesizer use the system
    /// default. Falls through rather than going silent when a chosen voice has been
    /// uninstalled since it was picked.
    static func resolve(_ identifier: String) -> AVSpeechSynthesisVoice? {
        if !identifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        // Empty means Automatic; a non-empty id that resolves to nil means the user
        // uninstalled their chosen voice, and falling through beats going silent.
        return catalog().best
    }

    /// True when the voice we'd actually use is a stock compact one. Drives the Settings
    /// nudge — the basic voices sound robotic enough that a user who never learns the
    /// better ones are free will reasonably conclude the feature isn't worth using.
    static func resolvedVoiceIsBasic(_ identifier: String) -> Bool {
        (resolve(identifier)?.quality ?? .default).rank <= AVSpeechSynthesisVoiceQuality.default.rank
    }

    // MARK: - System Settings

    /// Opens System Settings where "Manage Voices…" lives.
    ///
    /// There is **no API** to download a voice or to open the voice sheet directly, so a
    /// deep link is the whole of what's available. The anchor names for the modern
    /// Settings app aren't published, so this tries the anchored URL and falls back to
    /// the pane root — `open` reports success as soon as the *pane* resolves, which is
    /// why the Settings copy spells out the full path rather than promising a landing
    /// spot. Same mechanism as `PermissionsManager` and `FnKeyBehavior.openKeyboardSettings`.
    static func openSpokenContentSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.universalaccess?Speech",
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.universalaccess"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}

extension AVSpeechSynthesisVoiceQuality {
    /// Sortable quality. The enum's raw values already ascend, but relying on that
    /// silently breaks if Apple inserts a case — naming the order keeps it explicit.
    var rank: Int {
        switch self {
        case .premium: return 2
        case .enhanced: return 1
        default: return 0
        }
    }
}
