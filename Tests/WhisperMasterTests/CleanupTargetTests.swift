import XCTest

@testable import WhisperMaster

final class CleanupTargetTests: XCTestCase {
    func testShippedModesKeepTheExistingPrompts() {
        XCTAssertEqual(CleanupTarget.light.prompt, CleanupPrompt.system)
        XCTAssertEqual(CleanupTarget.polish.prompt, CleanupPrompt.grammarPolish)
    }

    func testFormatTargetsAreDistinctFromTheShippedPrompts() {
        XCTAssertNotEqual(CleanupTarget.slack.prompt, CleanupPrompt.system)
        XCTAssertNotEqual(CleanupTarget.email.prompt, CleanupPrompt.system)
        XCTAssertNotEqual(CleanupTarget.code.prompt, CleanupPrompt.system)
        XCTAssertNotEqual(CleanupTarget.slack.prompt, CleanupTarget.email.prompt)
        XCTAssertNotEqual(CleanupTarget.email.prompt, CleanupTarget.code.prompt)
    }

    func testOnlyLightForbidsRephrase() {
        XCTAssertFalse(CleanupTarget.light.allowsRephrase)
        for target in CleanupTarget.allCases where target != .light {
            XCTAssertTrue(target.allowsRephrase, "\(target.rawValue) should allow rephrase")
        }
    }

    func testRawValuesAreTheEvalTargetIds() {
        XCTAssertEqual(CleanupTarget.allCases.map(\.rawValue), [
            "light", "polish", "slack", "email", "code",
        ])
    }

    func testUnknownTargetStringDoesNotResolve() {
        XCTAssertNil(CleanupTarget(rawValue: "sms"))
        XCTAssertNil(CleanupTarget(rawValue: "Light"))
    }
}
