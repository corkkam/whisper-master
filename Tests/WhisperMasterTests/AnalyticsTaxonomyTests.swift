import XCTest
@testable import WhisperMaster

/// The event catalog's own invariants.
///
/// These matter more than they look: the catalog is the contract two dashboards
/// and a set of GA custom dimensions are built against, and every failure mode
/// here is silent — a mis-shaped name is dropped by GA with a `204`, a missing
/// `category` just makes a feature invisible in the one breakdown that is
/// supposed to cover everything.
final class AnalyticsTaxonomyTests: XCTestCase {
    /// One representative of every case. Kept exhaustive by hand because Swift
    /// gives no `CaseIterable` for an enum with associated values — the switch in
    /// `category` is what forces a new case to be considered, and this list is
    /// what makes the rest of the assertions cover it.
    private let allEvents: [AnalyticsEvent] = [
        .appLaunched,
        .onboardingFinished,
        .updateInstalled(from: "1.0.1", to: "1.1.0"),
        .dictationCompleted(engine: "parakeet", duration: 12, wordCount: 30),
        .dictationDiscarded(reason: .cancelled),
        .dictationUndelivered(copied: true),
        .hotkeyChanged(to: "fn"),
        .fnKeyClaim(restored: false),
        .handsFreeUsed,
        .assistantInvoked,
        .assistantRouted(route: .agent),
        .assistantToolRun(tool: "create_note", succeeded: true),
        .assistantFailed(reason: .budgetExhausted),
        .noteCreated(source: .agent, hasAudio: true),
        .notePinned(pinned: true),
        .noteAudioPlayed,
        .noteDeleted,
        .reminderCreated(source: .manual, repeating: false),
        .reminderCompleted(repeating: true),
        .reminderRestored,
        .reminderArchiveCleared,
        .connectorLinked(provider: "slack", linked: true),
        .approvalDecided(tool: "send_message", decision: .timedOut),
        .answerSpoken(voice: .natural),
        .naturalVoiceInstalled,
        .cleanupModelDownloaded,
        .cleanupApplied,
        .permissionState(accessibility: true, microphone: false),
        .settingToggled(setting: "speakAnswers", enabled: false),
        .appCrashed(nil),
        .failureOccurred(domain: "audio", kind: "engineRestartFailed"),
    ]

    /// The whole point of `category`: one breakdown that covers every signal. A
    /// case that forgot it would silently drop out of the feature-adoption view
    /// rather than showing up as an error anywhere.
    func testEveryEventCarriesItsCategory() {
        for event in allEvents {
            XCTAssertEqual(
                event.parameters["category"], event.category.rawValue,
                "\(event.name) did not carry its category into parameters"
            )
        }
    }

    /// GA4 accepts `[A-Za-z][A-Za-z0-9_]{0,39}` and silently discards anything
    /// else — with a `204`, so a bad name looks exactly like a working one until
    /// the report is empty weeks later.
    func testGoogleNamesAreAcceptableToGA4() {
        for event in allEvents {
            let name = event.googleName
            XCTAssertEqual(
                name, GA4Limits.eventName(name),
                "\(name) is not already GA4-legal and would be silently rewritten"
            )
            XCTAssertLessThanOrEqual(name.count, 40, "\(name) is over GA4's 40-character limit")
        }
    }

    /// Reserved names and prefixes are dropped by GA on sight.
    func testGoogleNamesAvoidReservedSpellings() {
        let reservedPrefixes = ["ga_", "google_", "firebase_"]
        let reservedNames: Set<String> = [
            "first_open", "session_start", "user_engagement", "in_app_purchase", "app_remove",
        ]
        for event in allEvents {
            let name = event.googleName
            XCTAssertFalse(reservedNames.contains(name), "\(name) is a GA4 reserved name")
            for prefix in reservedPrefixes {
                XCTAssertFalse(name.hasPrefix(prefix), "\(name) uses the reserved prefix \(prefix)")
            }
        }
    }

    /// Both name spaces must be injective, or two different signals merge into one
    /// series and neither number means anything afterwards.
    func testEventNamesAreUnique() {
        let posthog = allEvents.map(\.name)
        let google = allEvents.map(\.googleName)
        XCTAssertEqual(Set(posthog).count, posthog.count, "duplicate PostHog event name")
        XCTAssertEqual(Set(google).count, google.count, "duplicate GA4 event name")
    }

    /// GA caps an event at 25 params and drops the excess after sorting, so a
    /// fat event loses data rather than erroring.
    func testNoEventExceedsTheGA4ParameterBudget() {
        for event in allEvents {
            // The event's own params plus the four base/session params the client
            // merges in (`app_version`, `os_version`, `platform`, `channel`,
            // `session_id`, `engagement_time_msec`).
            let effective = event.parameters.count + 6
            XCTAssertLessThanOrEqual(
                effective, GA4Limits.maxParametersPerEvent,
                "\(event.googleName) would overflow GA4's per-event parameter cap"
            )
        }
    }

    // MARK: - Account

    /// Email and name are optional in Clerk and often absent right after an OAuth
    /// sign-in. An empty string is not a value — sending one would put `""` on the
    /// person profile and make the field useless for filtering.
    func testPersonPropertiesOmitEmptyOptionalFields() {
        let bare = AnalyticsAccount(id: "user_2abc", email: nil, name: "")
        XCTAssertEqual(bare.personProperties["clerkUserId"], "user_2abc")
        XCTAssertNil(bare.personProperties["email"])
        XCTAssertNil(bare.personProperties["name"])
    }

    /// Channel and version live on the person as well as on every event, because
    /// PostHog's cohort and retention maths runs off the person profile — a
    /// property that exists only on events cannot define a cohort.
    func testPersonPropertiesCarryChannelAndVersion() {
        let account = AnalyticsAccount(id: "user_2abc", email: "a@b.com", name: "Jane")
        XCTAssertEqual(account.personProperties["channel"], ReleaseChannel.current.rawValue)
        XCTAssertEqual(account.personProperties["appVersion"], AnalyticsIdentity.currentVersion)
        XCTAssertEqual(account.personProperties["email"], "a@b.com")
        XCTAssertEqual(account.personProperties["name"], "Jane")
    }

    /// The account must never reach an event body. The identity lives on the
    /// profile alone, so an exported event stream is not a customer list.
    func testNoEventParameterCarriesAccountIdentity() {
        let forbidden = ["clerkUserId", "email", "name", "userId"]
        for event in allEvents {
            for key in forbidden {
                XCTAssertNil(
                    event.parameters[key],
                    "\(event.name) leaked \(key) into its event parameters"
                )
            }
        }
    }
}
