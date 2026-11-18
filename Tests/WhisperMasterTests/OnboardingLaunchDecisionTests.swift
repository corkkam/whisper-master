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
