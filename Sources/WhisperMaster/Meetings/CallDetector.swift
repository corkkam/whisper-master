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
    /// Bundle ids of every process playing audio right now. Gathered only while an
    /// app that also records voice messages is on the mic
    /// (`MeetingAppCatalog.voiceMessageApps`); empty otherwise.
    var outputBundleIDs: [String] = []
}

/// Turns polled mic evidence into "a call started" and "the call ended".
///
/// Pure and clock-injected so the debounces are tested rather than discovered on a
/// live call. Both debounces exist for a reason seen in real use:
/// - **Start waits `startHold`.** A browser opens the mic for a moment for a
///   permission check. A call holds it. A voice message can hold it longer than
///   any hold worth waiting, so the apps that record them must also be playing
///   audio (`MeetingAppCatalog.voiceMessageApps`): a call plays the other side, a
///   message being recorded plays nothing.
/// - **End waits `endHold`.** Switching headphones, or an app reopening its audio
///   unit after a route change, drops the mic for a second or two. Ending the
///   meeting there would split one meeting into two notes.
/// - **Once started, a call lasts as long as its app holds the mic.** It is not
///   re-detected on every poll: a browser call is only *found* by a tab title or a
///   calendar event, and neither survives switching tabs or a meeting running
///   over, while the mic does.
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
            if MeetingAppCatalog.voiceMessageApps.contains(family),
               !evidence.outputBundleIDs.contains(where: { MeetingAppCatalog.family(of: $0) == family }) {
                continue
            }
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

    /// Whether any process of `family` is on the mic. Helpers count for their app,
    /// and another call app listed first does not hide it.
    static func holdsMic(_ family: String, in evidence: CallEvidence) -> Bool {
        evidence.micBundleIDs.contains { MeetingAppCatalog.family(of: $0) == family }
    }

    /// Feed one poll. Returns an event only on a confirmed transition.
    mutating func update(_ evidence: CallEvidence, ignoring ignored: Set<String> = [],
                         now: Date) -> Event? {
        if let active {
            // The call's own app still on the mic: the meeting continues, whatever
            // tab is in front and whatever the calendar says.
            if Self.holdsMic(active.bundleFamily, in: evidence) {
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

        guard let seen = Self.call(in: evidence, ignoring: ignored) else {
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
