import XCTest

@testable import WhisperMaster

/// Whether a signed-in launch shows onboarding.
final class OnboardingLaunchDecisionTests: XCTestCase {
    private func decide(
        hasRecord: Bool = false, mic: Bool = false, accessibility: Bool = false,
        pending: Bool = true, signingOut: Bool = false
    ) -> OnboardingLaunchDecision {
        OnboardingLaunchDecision.resolve(
            hasRecord: hasRecord, micGranted: mic, accessibilityGranted: accessibility,
            pending: pending, signOutInFlight: signingOut)
    }

    /// An existing install with no record and both grants is past onboarding.
    func testSeedsAnAccountWithNoRecordAndBothGrants() {
        XCTAssertEqual(decide(mic: true, accessibility: true), .seedAsSeen)
    }

    func testShowsANewAccount() {
        XCTAssertEqual(decide(), .show)
        XCTAssertEqual(decide(mic: true), .show)
        XCTAssertEqual(decide(hasRecord: true, mic: true, accessibility: true), .show)
    }

    func testSkipsWhenComplete() {
        XCTAssertEqual(decide(hasRecord: true, pending: false), .skip)
    }

    func testSkipsWhileASignOutIsInFlight() {
        XCTAssertEqual(decide(signingOut: true), .skip)
        XCTAssertEqual(decide(mic: true, accessibility: true, signingOut: true), .skip)
    }

    /// A nil user has no record to look up or seed, so it is shown setup, as the
    /// launch always did, even with both grants on. A sign-out still holds it.
    func testANilUserIsShownAndNeverSeeded() {
        for (mic, accessibility) in [(false, false), (true, true)] {
            XCTAssertEqual(
                OnboardingLaunchDecision.resolve(
                    userID: nil, micGranted: mic, accessibilityGranted: accessibility, signOutInFlight: false),
                .show)
        }
        XCTAssertEqual(
            OnboardingLaunchDecision.resolve(
                userID: nil, micGranted: true, accessibilityGranted: true, signOutInFlight: true),
            .skip)
    }
}

/// The `AppDelegate` entry with a real id, which reads the account's record.
/// The nil user is `OnboardingLaunchDecisionTests.testANilUserIsShownAndNeverSeeded`.
final class OnboardingLaunchDecisionRecordTests: XCTestCase {
    private let key = "WhisperMaster.onboardingSeenSteps.v1"
    private var saved: Any?
    private let user = "onboarding-launch-tests-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: key)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    private func decide(mic: Bool = false, accessibility: Bool = false) -> OnboardingLaunchDecision {
        OnboardingLaunchDecision.resolve(
            userID: user, micGranted: mic, accessibilityGranted: accessibility, signOutInFlight: false)
    }

    func testANewAccountWithNoRecordIsShownSetup() {
        XCTAssertFalse(OnboardingProgress.hasRecord(userID: user))
        XCTAssertEqual(decide(), .show)
    }

    /// The migration: no record, both grants already on.
    func testANewAccountWithBothGrantsIsSeeded() {
        XCTAssertEqual(decide(mic: true, accessibility: true), .seedAsSeen)
    }

    func testAFinishedAccountIsNotShownSetup() {
        OnboardingProgress.markSeen(OnboardingStep.allCases.map(\.id), userID: user)
        XCTAssertEqual(decide(), .skip)
        XCTAssertEqual(decide(mic: true, accessibility: true), .skip)
    }
}

/// The hold that keeps the sign-in gate up while Clerk's sign-out is on the
/// network, ended by the call returning or by `SignOutHold.limit`.
final class SignOutHoldTests: XCTestCase {
    func testTheCallReturningEndsTheHold() {
        var hold = SignOutHold()
        let token = hold.begin()
        XCTAssertTrue(hold.inFlight)
        XCTAssertTrue(hold.end(token))
        XCTAssertFalse(hold.inFlight)
        // The limit's timer then finds nothing to end.
        XCTAssertFalse(hold.end(token))
    }

    /// An older sign-out's timer must not release a newer sign-out's gate.
    func testAStaleEndChangesNothing() {
        var hold = SignOutHold()
        let first = hold.begin()
        _ = hold.end(first)
        let second = hold.begin()
        XCTAssertFalse(hold.end(first))
        XCTAssertTrue(hold.inFlight)
        XCTAssertTrue(hold.end(second))
    }
}

/// Locks what "this account has onboarded" means, so the new flow cannot
/// re-onboard an existing account.
final class OnboardingProgressTests: XCTestCase {
    private let key = "WhisperMaster.onboardingSeenSteps.v1"
    private var saved: Any?
    private let user = "onboarding-progress-tests-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: key)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testANewAccountIsPending() {
        XCTAssertFalse(OnboardingProgress.hasRecord(userID: user))
        XCTAssertFalse(OnboardingProgress.isComplete(userID: user))
        XCTAssertEqual(OnboardingProgress.pendingSteps(userID: user), [.permissions])
    }

    func testPermissionsCompletes() {
        OnboardingProgress.markSeen(["permissions"], userID: user)
        XCTAssertTrue(OnboardingProgress.isComplete(userID: user))
        XCTAssertEqual(OnboardingProgress.pendingSteps(userID: user), [])
    }

    func testTheLegacyPairCompletes() {
        OnboardingProgress.markSeen(["microphone"], userID: user)
        XCTAssertFalse(OnboardingProgress.isComplete(userID: user))
        OnboardingProgress.markSeen(["accessibility"], userID: user)
        XCTAssertTrue(OnboardingProgress.isComplete(userID: user))
        XCTAssertEqual(OnboardingProgress.pendingSteps(userID: user), [])
    }

    func testDoneCompletes() {
        OnboardingProgress.markSeen(["done"], userID: user)
        XCTAssertTrue(OnboardingProgress.isComplete(userID: user))
    }

    func testTheStepIDsAreUnchanged() {
        XCTAssertEqual(OnboardingStep.allCases.map(\.id), ["permissions"])
        XCTAssertEqual(NotchOnboardingStep.allCases.map(\.rawValue), [0, 1, 2, 3])
    }
}
