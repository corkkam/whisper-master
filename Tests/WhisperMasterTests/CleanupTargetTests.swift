import XCTest

@testable import WhisperMaster

final class CleanupTargetTests: XCTestCase {

    /// **One system prompt now, for every target.** S1-mini takes its destination from
    /// the control line's axes rather than from differently-worded instructions, so
    /// the per-target prompts the outgoing general model needed are gone. This
    /// replaces the old assertion that each target carried its own prompt.
    func testEveryTargetSharesTheOneTrainedSystemPrompt() {
        for target in CleanupTarget.allCases {
            XCTAssertEqual(target.prompt, CleanupPrompt.system, target.rawValue)
        }
    }

    /// The difference between targets lives in the axes.
    func testTargetsAreDistinguishedByTheirAxes() {
        let light = CleanupPrompt.axes(for: .light)
        let polish = CleanupPrompt.axes(for: .polish)
        let slack = CleanupPrompt.axes(for: .slack)
        let email = CleanupPrompt.axes(for: .email)

        XCTAssertEqual(light.0, .semiFormal)
        XCTAssertEqual(polish.0, .formal, "the heavier mode is formal styling")
        XCTAssertEqual(slack.0, .casual, "a message to a colleague is not formal writing")
        XCTAssertEqual(email.2, .email, "the only target that changes the context axis")

        XCTAssertNotEqual(light.0, polish.0)
        XCTAssertNotEqual(light.0, slack.0)
        XCTAssertNotEqual(light.2, email.2)
    }

    /// **`.code` is the honest gap.** S1-mini has no code notion and no axis that
    /// would give it one, so it takes the plain reading rather than being faked with
    /// a styling that means something else. Pinned so the compromise is visible
    /// rather than mistaken for an oversight.
    func testCodeFallsBackToThePlainReadingRatherThanFakingOne() {
        XCTAssertEqual(CleanupPrompt.axes(for: .code).0, CleanupPrompt.axes(for: .light).0)
        XCTAssertEqual(CleanupPrompt.axes(for: .code).2, .general)
    }

    /// The control line is the format the model was trained on; a stray space or a
    /// renamed axis is the kind of thing that degrades output without erroring.
    func testTheControlLinePrefixesTheTranscript() {
        let turn = CleanupPrompt.userTurn("so um ship it", target: .slack)
        XCTAssertEqual(
            turn, "[Styling: casual] [Structure: prose] [Context: general]\nso um ship it")
    }

    func testTheShippedTwoToggleCallMapsOntoTargets() {
        XCTAssertEqual(
            CleanupPrompt.userTurn("x", grammarPolish: false),
            CleanupPrompt.userTurn("x", target: .light))
        XCTAssertEqual(
            CleanupPrompt.userTurn("x", grammarPolish: true),
            CleanupPrompt.userTurn("x", target: .polish))
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
