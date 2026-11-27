import Foundation

/// What a person can do with and without an account.
///
/// Owner decision D2, 2026-11-27: a user can dictate before sign-in. Sign-in is
/// still required for sync, the assistant and the beta update track. This is the
/// one table those rules live in, so a call site asks it instead of reading the
/// Clerk session itself, and `AccountGateTests` pins every row.
///
/// It decides nothing about *who* is signed in. `AppDelegate` owns that (a Clerk
/// session, held false while a sign-out is on the network) and passes it in.
enum AccountFeature: CaseIterable {
    /// Push-to-talk, the tray's Start Dictation, setup, local cleanup and the
    /// local history. Never behind an account.
    case dictation
    /// Notes sync and usage sync. Nothing is sent without a session.
    case sync
    /// The fn + control chord and everything the assistant reaches: connectors,
    /// notes and reminders by voice, meeting notes and the coding-agent key.
    case assistant
    /// The beta Sparkle channel (`BetaAccess`). Signed out, a user gets stable.
    case betaUpdates

    var needsAccount: Bool { self != .dictation }

    func isAllowed(signedIn: Bool) -> Bool { signedIn || !needsAccount }
}

/// When the launch may stop waiting for Clerk to say who is signed in.
///
/// Clerk restores a saved session asynchronously, so at launch every user looks
/// signed out for a moment. Setup is scoped to the account (`OnboardingProgress`),
/// so it waits for the answer, but not for ever: offline, Clerk may never answer,
/// and a person who can dictate with no account must not wait on one.
enum SessionResolution {
    static let grace: TimeInterval = 4

    static func isResolved(sessionLoaded: Bool, secondsSinceLaunch: TimeInterval) -> Bool {
        sessionLoaded || secondsSinceLaunch >= grace
    }
}
