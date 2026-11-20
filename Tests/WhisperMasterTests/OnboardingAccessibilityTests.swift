import XCTest

@testable import WhisperMaster

/// What VoiceOver reads, and in what order.
final class OnboardingAccessibilityTests: XCTestCase {
    func testReadingOrder() {
        XCTAssertEqual(OnboardingCopy.readingOrder, [
            .headline, .body, .actions, .topBarLine, .stepProgress, .back, .settings, .close,
        ])
        // Higher priority reads first, so the priorities fall along the order.
        let priorities = OnboardingCopy.readingOrder.map(OnboardingCopy.sortPriority)
        XCTAssertEqual(priorities, priorities.sorted(by: >))
        XCTAssertEqual(Set(priorities).count, priorities.count)
    }

    /// The capsule value and the capsule colour come from one predicate: a
    /// microphone that is on, whose voice test was skipped with Not now, reads
    /// "Microphone done", and `StepDots` draws a past step signal exactly when
    /// that predicate holds.
    func testTheStepValueAndColourShareOnePredicate() {
        XCTAssertEqual(
            OnboardingCopy.stepProgressValue(current: .openAtLogin, micOn: true, typingOn: false, loginOn: false),
            "Step 3 of 4, Start with your Mac. Microphone done, Typing skipped.")
        for step in NotchOnboardingStep.allCases where step != .ready {
            for (mic, typing, login) in [(true, false, true), (false, true, false)] {
                let done = OnboardingCopy.stepIsDone(step, micOn: mic, typingOn: typing, loginOn: login)
                let value = OnboardingCopy.stepProgressValue(current: .ready, micOn: mic, typingOn: typing, loginOn: login)
                XCTAssertTrue(value.contains("\(step.title) \(done ? "done" : "skipped")"), value)
            }
        }
    }
}
