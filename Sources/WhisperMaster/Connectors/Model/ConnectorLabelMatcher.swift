import Foundation

/// Resolves spoken text to a named connector instance — "what's on my **work**
/// calendar" → the instance labelled "Work".
///
/// This exists because in a dictation app the instance label isn't chrome, it's the
/// *handle the user says out loud*. Pure and synchronous so it's cheap enough to run
/// on every transcript and fully unit-testable with no store, no EventKit and no
/// model.
///
/// Conservative by construction, like `DayQueryDetector` and `CommandDetector`: it
/// returns nil rather than guessing. A nil answer means "no instance was named", and
/// the caller then merges across all of them (reads) or uses the kind default
/// (writes) — both better outcomes than silently reading the wrong account.
enum ConnectorLabelMatcher {
    /// Words that carry no distinguishing power: filler, possessives, and the
    /// vocabulary of the connectors themselves. A label reduced to nothing but these
    /// can't be matched, and a query containing only these names no instance.
    ///
    /// This is what stops "what's on my calendar" from matching an instance merely
    /// labelled "Calendar" while the user meant all of them.
    private static let stopwords: Set<String> = [
        "a", "an", "the", "my", "mine", "our", "me", "i",
        "whats", "what", "whos", "who", "hows", "how", "is", "on", "in", "at", "for",
        "do", "does", "did", "have", "has", "show", "tell", "get", "list", "check",
        "today", "todays", "tomorrow", "now", "next", "this", "week", "day", "days",
        "schedule", "agenda", "calendar", "calendars", "event", "events", "meeting",
        "meetings", "mail", "email", "emails", "inbox", "message", "messages",
        "task", "tasks", "issue", "issues", "file", "files", "account", "connector",
        "google", "apple", "microsoft", "outlook", "gmail", "slack", "notion",
        "linear", "github", "zoom", "asana", "drive", "ical", "icloud", "exchange",
    ]

    /// Split into lowercase alphanumeric tokens. Apostrophes are dropped rather than
    /// split on, so "what's" becomes "whats" (which is a stopword) instead of
    /// "what" + "s".
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// The tokens that actually distinguish one instance from another: everything
    /// left after stopwords and the kind's own display words are removed.
    ///
    /// "Google Calendar Work" → ["work"]. "Personal" → ["personal"].
    static func distinctiveTokens(for instance: ConnectorInstance) -> Set<String> {
        let kindWords = Set(tokens(instance.kind.displayName))
        return Set(tokens(instance.displayLabel))
            .subtracting(kindWords)
            .subtracting(stopwords)
    }

    /// The best instance named by `spoken`, or nil if none is named or the answer is
    /// ambiguous.
    ///
    /// Scoring is deliberately simple — how many of an instance's distinctive tokens
    /// the utterance contains. An instance with no distinctive tokens (label is just
    /// the kind name, e.g. the migrated "Google Calendar") can never be matched by
    /// name, which is correct: the user never gave it one.
    ///
    /// A tie is resolved to nil, not to the first candidate. Two instances the
    /// utterance names equally well is exactly the case where guessing is wrong.
    static func match(_ spoken: String, in instances: [ConnectorInstance]) -> ConnectorInstance? {
        let said = Set(tokens(spoken))
        guard !said.isEmpty else { return nil }

        var best: (instance: ConnectorInstance, score: Int)?
        var tied = false

        for instance in instances {
            let distinctive = distinctiveTokens(for: instance)
            guard !distinctive.isEmpty else { continue }
            let score = distinctive.intersection(said).count
            guard score > 0 else { continue }
            if let current = best {
                if score > current.score {
                    best = (instance, score)
                    tied = false
                } else if score == current.score {
                    tied = true
                }
            } else {
                best = (instance, score)
            }
        }

        return tied ? nil : best?.instance
    }

    /// Whether the utterance names *any* instance in the set. Lets a caller choose
    /// between "merge everything" and "route to one" before doing any work.
    static func namesAnInstance(_ spoken: String, in instances: [ConnectorInstance]) -> Bool {
        match(spoken, in: instances) != nil
    }
}
