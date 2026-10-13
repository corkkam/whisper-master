import Foundation

/// A call another app is running: what to call it, and which bundle family to
/// tap for its audio.
struct DetectedCall: Equatable, Sendable {
    /// Shown on the notch: "Slack huddle", "Google Meet".
    var name: String
    /// The bundle prefix to tap (`MeetingAppCatalog.family`).
    var bundleFamily: String
    /// The calendar event in progress, when there is one. Becomes the note title.
    var calendarTitle: String?
}

/// One poll's worth of evidence, gathered off the main actor.
struct CallEvidence: Equatable, Sendable {
    /// Bundle ids of every process using an input device right now, our own excluded.
    var micBundleIDs: [String]
    /// Window titles of the browsers among `micBundleIDs`, keyed by bundle id.
    var browserTitles: [String: [String]] = [:]
    /// The calendar meeting in progress, if any.
    var calendarTitle: String?
}

/// Turns polled mic evidence into "a call started" and "the call ended".
///
/// Pure and clock-injected so the debounces are tested rather than discovered on a
/// live call. Both debounces exist for a reason seen in real use:
/// - **Start waits `startHold`.** Slack opens the mic for a moment to record a
///   voice clip, a browser does for a permission check. A call holds it.
/// - **End waits `endHold`.** Switching headphones, or an app reopening its audio
///   unit after a route change, drops the mic for a second or two. Ending the
///   meeting there would split one meeting into two notes.
struct CallDetector {
    enum Event: Equatable {
        case started(DetectedCall)
        case ended
    }

    static let startHold: TimeInterval = 3
    static let endHold: TimeInterval = 15

    /// The call seen on the last poll, whether or not it is confirmed yet.
    private var candidate: DetectedCall?
    private var candidateSince: Date?
    /// The call announced with `.started`, until `.ended`.
    private(set) var active: DetectedCall?
    private var missingSince: Date?

    /// Which call, if any, this evidence shows. Native apps outrank browsers,
    /// because a browser can hold the mic for something else while the native
    /// app carries the call.
    static func call(in evidence: CallEvidence, ignoring ignored: Set<String> = []) -> DetectedCall? {
        for id in evidence.micBundleIDs {
            guard let name = MeetingAppCatalog.nativeName(for: id),
                  let family = MeetingAppCatalog.family(of: id),
                  !ignored.contains(family)
            else { continue }
            return DetectedCall(name: name, bundleFamily: family, calendarTitle: evidence.calendarTitle)
        }
        for id in evidence.micBundleIDs where MeetingAppCatalog.isBrowser(id) {
            guard let family = MeetingAppCatalog.family(of: id), !ignored.contains(family)
            else { continue }
            let titles = evidence.browserTitles[id] ?? evidence.browserTitles[family] ?? []
            if let name = titles.lazy.compactMap(MeetingAppCatalog.webMeetingName(inTitle:)).first {
                return DetectedCall(name: name, bundleFamily: family, calendarTitle: evidence.calendarTitle)
            }
            // A browser on the mic during a calendar meeting is almost always
            // that meeting, even when the tab title does not say so.
            if evidence.calendarTitle != nil {
                return DetectedCall(name: "Browser call", bundleFamily: family,
                                    calendarTitle: evidence.calendarTitle)
            }
        }
        return nil
    }

    /// Feed one poll. Returns an event only on a confirmed transition.
    mutating func update(_ evidence: CallEvidence, ignoring ignored: Set<String> = [],
                         now: Date) -> Event? {
        let seen = Self.call(in: evidence, ignoring: ignored)

        if let active {
            // Same app still on the mic: the meeting continues.
            if let seen, seen.bundleFamily == active.bundleFamily {
                missingSince = nil
                return nil
            }
            let since = missingSince ?? now
            missingSince = since
            guard now.timeIntervalSince(since) >= Self.endHold else { return nil }
            self.active = nil
            missingSince = nil
            candidate = nil
            candidateSince = nil
            return .ended
        }

        guard let seen else {
            candidate = nil
            candidateSince = nil
            return nil
        }
        if candidate?.bundleFamily != seen.bundleFamily {
            candidate = seen
            candidateSince = now
        }
        guard let since = candidateSince, now.timeIntervalSince(since) >= Self.startHold
        else { return nil }
        active = seen
        return .started(seen)
    }
}
