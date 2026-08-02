import Foundation

/// A cheap, pure gate that answers one question of a finished transcript — *is
/// this the user asking about their day / schedule?* — without touching any model.
///
/// **⚠️ It may only run on a capture the user armed with the assistant chord** — it
/// is called from exactly one place, `DictationViewModel.routeCommandCapture`, and
/// must not be called from anywhere upstream of a paste.
///
/// It used to also run over every ordinary push-to-talk dictation, routing one into a
/// calendar answer whenever the words looked like a question about "my day". That
/// path *suppresses the paste*, so every false positive silently ate the user's
/// transcript — and no keyword list can tell "what's my schedule?" (a question for
/// the app) from "what's my schedule for the sprint?" (words meant for the cursor).
///
/// Inside an armed capture the same imprecision is harmless, which is the whole
/// distinction: the chord has *already* decided the words aren't going to the cursor,
/// so this only picks which handling an assistant capture gets. A false positive
/// costs a wrong-shaped answer, not a lost transcript.
enum DayQueryDetector {
    /// Leading wake phrases (the dictation hotkey path). Sorted longest-first at
    /// match time so the fullest phrase wins.
    private static let wakePhrases = [
        "hey whisper what's my day", "hey whisper what is my day",
        "hey whisper what's on my calendar", "hey whisper how's my day",
        "hey whisper what's my schedule",
        "what's my day", "what is my day", "what's my day look like",
        "what does my day look like", "how's my day", "how is my day",
        "what's on my calendar", "what is on my calendar", "what's on today",
        "what do i have today", "what's my schedule", "what is my schedule",
        "what's on my schedule", "what's on my plate today",
        "what's coming up today", "what's next today", "what's happening today",
    ]

    /// True when the transcript looks like a "what's my day" question. Matches a
    /// leading wake phrase, or (looser) any phrase that mentions the user's own
    /// day/calendar/schedule as a question.
    static func matches(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !lower.isEmpty else { return false }
        for phrase in wakePhrases.sorted(by: { $0.count > $1.count }) {
            if lower == phrase || lower.hasPrefix(phrase + " ") || lower.hasPrefix(phrase + "?") {
                return true
            }
        }
        // Looser catch: a possessive "my {day,calendar,schedule,meetings}" asked
        // as a question anywhere in a short utterance.
        let mentionsMine = ["my day", "my calendar", "my schedule", "my meetings", "my agenda"]
            .contains { lower.contains($0) }
        let isQuestion = lower.hasSuffix("?")
            || lower.hasPrefix("what") || lower.hasPrefix("how") || lower.hasPrefix("do i")
            || lower.hasPrefix("when") || lower.hasPrefix("show me")
        return mentionsMine && isQuestion && lower.count < 80
    }
}

/// A connector that was asked for data but couldn't provide it, and why. Surfaced in
/// the answer so a gap is stated rather than looking like an empty day.
struct DaySummaryGap: Equatable, Sendable {
    let instanceLabel: String
    let reason: ConnectorError
}

/// The result of a day query — the compact answer surfaced in the notch. Kept to
/// a headline + one detail line so it fits the notch band like the other banners.
struct DaySummary: Equatable, Sendable {
    let headline: String
    let detail: String
    /// Full event list behind the summary, for a future richer surface / logging.
    let events: [DayEvent]
    /// Connectors that were on but couldn't contribute — surfaced so the answer is
    /// honest about gaps rather than reporting a quiet, wrong "you're clear".
    let gaps: [DaySummaryGap]
    /// The instance label this answer was narrowed to, when the user named one
    /// ("what's on my *work* calendar"). nil for a merged answer across all of them.
    let scopedTo: String?

    var accessibilityText: String {
        var parts = [headline, detail]
        if !gaps.isEmpty {
            let names = gaps.map(\.instanceLabel).joined(separator: ", ")
            parts.append("Couldn't read: \(names).")
        }
        return parts.joined(separator: ". ")
    }
}

/// Builds a `DaySummary` by fanning out across connector **instances**.
///
/// Two behaviours, per the addressing decision:
///
/// - An **unqualified** read merges every enabled event-providing instance and tags
///   each event with the instance it came from. "What's my day" genuinely means all of
///   it, so answering from one default account would reproduce the same class of quiet
///   wrongness as the original bug.
/// - A read that **names** an instance ("what's on my work calendar") is scoped to it.
///
/// Failures are recorded per instance and reported as `gaps`, never swallowed.
@MainActor
enum DaySummaryService {
    /// The local-only build: EventKit instances only, synchronous.
    ///
    /// Kept because the surfaces that render on appearance (`TodayView`, the Connectors
    /// panel) must not block on a network round-trip to draw. API-backed instances are
    /// reported as pending and filled in by `buildAsync`.
    static func build(store: ConnectorInstanceStore,
                      spokenQuery: String? = nil,
                      now: Date = Date()) -> DaySummary {
        let targets = resolveTargets(store: store, spokenQuery: spokenQuery)
        var collector = Collector()
        for instance in targets.instances where !instance.config.isNetworkBacked {
            guard let provider = ProviderRegistry.eventProvider(for: instance) else { continue }
            collector.absorb(provider.todaysEvents(for: instance, now: now),
                             instance: instance, store: store)
        }
        return collector.finish(now: now, scopedTo: targets.scoped?.displayLabel)
    }

    /// The full build, including API-backed instances. Used by the day-query path, which
    /// is already asynchronous and where waiting a moment for real data is the point.
    static func buildAsync(store: ConnectorInstanceStore,
                           spokenQuery: String? = nil,
                           now: Date = Date()) async -> DaySummary {
        let targets = resolveTargets(store: store, spokenQuery: spokenQuery)
        return await buildAsync(store: store,
                                instances: targets.instances,
                                scopedTo: targets.scoped?.displayLabel,
                                now: now)
    }

    /// Build from an **explicit** instance set, for a caller that has already decided
    /// which connections answer.
    ///
    /// `ToolRouter` is that caller: it resolves the tool call's `connector` argument
    /// against the same candidates and then needs the fan-out run over exactly that
    /// result. Before this existed it resolved the targets and then threw them away,
    /// calling `buildAsync(store:)` with no query — so "what's on my *work* calendar"
    /// merged **every** calendar and stamped the answer with the one label the user
    /// happened to name. Passing the label back in to be re-matched would work, but
    /// re-deriving the same answer in two places is what let them disagree in the
    /// first place.
    static func buildAsync(store: ConnectorInstanceStore,
                           instances: [ConnectorInstance],
                           scopedTo: String?,
                           now: Date = Date()) async -> DaySummary {
        var collector = Collector()
        for instance in instances {
            if instance.config.isNetworkBacked {
                guard let provider = ProviderRegistry.googleCalendarAPI,
                      instance.kind == .googleCalendar else { continue }
                collector.absorb(await provider.todaysEventsAsync(for: instance, now: now),
                                 instance: instance, store: store)
            } else if let provider = ProviderRegistry.eventProvider(for: instance) {
                collector.absorb(provider.todaysEvents(for: instance, now: now),
                                 instance: instance, store: store)
            }
        }
        return collector.finish(now: now, scopedTo: scopedTo)
    }

    /// Which instances answer this question: the one it names, else all of them.
    private static func resolveTargets(
        store: ConnectorInstanceStore, spokenQuery: String?
    ) -> (instances: [ConnectorInstance], scoped: ConnectorInstance?) {
        let candidates = store.readable(providing: .events)
        let scoped = spokenQuery.flatMap { ConnectorLabelMatcher.match($0, in: candidates) }
        return (scoped.map { [$0] } ?? candidates, scoped)
    }

    /// Accumulates one fan-out: dedupes events, records per-instance failures, and
    /// keeps the sync and async paths from drifting apart.
    ///
    /// `@MainActor` restated — a nested type doesn't inherit the enclosing enum's
    /// isolation, and this touches the observable store.
    @MainActor
    private struct Collector {
        private var events: [DayEvent] = []
        private var gaps: [DaySummaryGap] = []
        private var seenEventIDs = Set<String>()

        mutating func absorb(_ outcome: ProviderReadOutcome<[DayEvent]>,
                             instance: ConnectorInstance,
                             store: ConnectorInstanceStore) {
            if let error = outcome.error {
                store.setError(instance.id, error)
                gaps.append(DaySummaryGap(instanceLabel: instance.displayLabel, reason: error))
                return
            }
            store.setError(instance.id, nil)
            // Two instances can legitimately overlap (one bound to every calendar,
            // another to a subset of it), so dedupe by event id. First writer wins,
            // which by `ordered` is the longest-standing instance.
            for event in outcome.value where !seenEventIDs.contains(event.id) {
                seenEventIDs.insert(event.id)
                events.append(event)
            }
        }

        func finish(now: Date, scopedTo: String?) -> DaySummary {
            let sorted = events.sorted { $0.start < $1.start }
            return DaySummary(
                headline: DaySummaryService.headline(for: sorted, gaps: gaps, now: now),
                detail: DaySummaryService.detail(for: sorted, now: now),
                events: sorted,
                gaps: gaps,
                scopedTo: scopedTo)
        }
    }

    private static func headline(for events: [DayEvent], gaps: [DaySummaryGap], now: Date) -> String {
        // A gap with nothing read is not an empty day — say so rather than claiming
        // the user is clear when we simply couldn't look.
        if events.isEmpty, !gaps.isEmpty { return "Couldn't read your calendar" }
        if events.isEmpty { return "Nothing on your calendar today" }
        let count = events.count
        let upcoming = events.filter { $0.end >= now }.count
        if upcoming == 0 { return "\(count) event\(count == 1 ? "" : "s") today, all done" }
        return "\(count) event\(count == 1 ? "" : "s") today"
    }

    private static func detail(for events: [DayEvent], now: Date) -> String {
        guard !events.isEmpty else { return "You're clear. Enjoy it." }
        // The next event that hasn't ended yet, else the first of the day.
        let next = events.first { $0.end >= now } ?? events[0]
        let when = next.isAllDay ? "all day" : timeString(next.start)
        // Name the connector when the user has more than one — "Next: 1:1 · 3pm ·
        // Work" is the payoff for having named them.
        let where_ = next.instanceLabel.isEmpty ? "" : " · \(next.instanceLabel)"
        return "Next: \(next.title) · \(when)\(where_)"
    }

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
