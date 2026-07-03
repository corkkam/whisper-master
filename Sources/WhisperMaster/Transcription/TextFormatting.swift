import Foundation

/// Reformats a finished dictation transcript into clean written form
/// (spoken numbers → digits, "at gmail dot com" → an email, times, currency,
/// punctuation). Implementations run the app's on-device LLM pass; the app only
/// ever talks to this seam so `FoundationModels` stays isolated to one file.
protocol TextFormatting: Sendable {
    /// Whether formatting can actually run right now (the on-device model is
    /// available). `false` means `format` is a pass-through.
    var isAvailable: Bool { get }

    /// `true` when `format` returns effectively instantly (rule-based, no model),
    /// so callers can skip a "Formatting…" status. `false` for the LLM pass.
    var isInstant: Bool { get }

    /// Warm the model so the first real `format` call isn't a cold start. A no-op
    /// for instant formatters (nothing to warm).
    func prewarm() async

    /// Return `text` reformatted to written form, or unchanged if unavailable
    /// or on any error — never throws, never loses the user's words.
    func format(_ text: String) async -> String
}

/// Used when on-device formatting isn't compiled in / supported (macOS < 26 or
/// no `FoundationModels`). Returns the transcript untouched.
struct PassthroughFormatter: TextFormatting {
    var isAvailable: Bool { false }
    var isInstant: Bool { true }
    func prewarm() async {}
    func format(_ text: String) async -> String { text }
}

/// Cheap pre-check so plain prose skips the LLM entirely and is injected
/// instantly — the model only runs when the transcript plausibly contains
/// something to reformat (spoken numbers, emails/URLs, currency, percent).
/// Biased toward running (a false "yes" only costs latency; a false "no" would
/// miss a conversion), but plain sentences match none of these and stay fast.
enum FormattingHeuristic {
    private static let numberWords =
        #"\b(zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|dozen)\b"#
    /// An email/URL said aloud ("… at gmail.com") with the dot already collapsed.
    private static let collapsedDomain = #"\bat\s+\S+\.\w{2,}"#

    static func mightNeedFormatting(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains(" dot ") || lower.contains("percent")
            || lower.contains("dollar") || lower.contains(" cent") {
            return true
        }
        return lower.range(of: numberWords, options: .regularExpression) != nil
            || lower.range(of: collapsedDomain, options: .regularExpression) != nil
    }
}

/// The persisted on/off preference for the formatting pass, owned here so
/// non-`@MainActor` callers (e.g. the remote session actor) can read it without
/// a cross-actor hop. On by default.
enum FormattingPreference {
    static let defaultsKey = "WhisperMaster.itnEnabled.v1"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }
}

/// Opt-in to route formatting through Apple's on-device language model instead
/// of the built-in deterministic rules. **Off by default** — while off, the
/// `FoundationModels` session is never created, so the model never loads and
/// consumes no resources. Experimental: slower and needs Apple Intelligence on.
enum AppleIntelligencePreference {
    static let defaultsKey = "WhisperMaster.useAppleIntelligence.v1"

    /// Defaults to `false` (absent key → off), so a fresh install loads no model.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}
