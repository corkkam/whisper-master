import XCTest
@testable import WhisperMaster

/// `RefinementDiff` turns the pasted deterministic text into the qwen-polished
/// text using the fewest keystrokes, under the constraint that the caret is at
/// the end so we can only delete-and-retype a suffix.
final class RefinementDiffTests: XCTestCase {

    func testIdenticalYieldsNoPlan() {
        XCTAssertNil(RefinementDiff.plan(pasted: "Send it to Jane.", refined: "Send it to Jane."))
    }

    func testEmptyRefinedIsNotSpecialCased() {
        // Not something we expect (guard blocks empties upstream), but the diff
        // itself should still describe deleting everything.
        let plan = RefinementDiff.plan(pasted: "hello", refined: "")
        XCTAssertEqual(plan, .init(deleteCount: 5, insert: ""))
    }

    /// A trailing self-correction: only the differing tail is rewritten, the long
    /// shared prefix is left untouched (few keystrokes, no flicker on the prefix).
    func testRewritesOnlyTheDifferingTail() {
        let plan = RefinementDiff.plan(
            pasted: "let's meet at three no wait four",
            refined: "let's meet at 4:00")
        XCTAssertNotNil(plan)
        // Shared prefix is "let's meet at ", so delete "three no wait four" (18)
        // and type "4:00".
        XCTAssertEqual(plan?.insert, "4:00")
        XCTAssertEqual(plan?.deleteCount, "three no wait four".count)
    }

    /// Pure deletion: refined is a prefix of pasted (dropped trailing filler).
    func testPureSuffixDeletion() {
        let plan = RefinementDiff.plan(pasted: "ship it today you know", refined: "ship it today")
        XCTAssertEqual(plan, .init(deleteCount: " you know".count, insert: ""))
    }

    /// A single mid-word change still deletes only from the divergence point to
    /// the end (we can't edit the middle without walking back to it).
    func testDivergenceInMiddleDeletesToEnd() {
        let plan = RefinementDiff.plan(pasted: "the cat sat", refined: "the dog sat")
        // Shared "the ", then "cat sat" differs from "dog sat".
        XCTAssertEqual(plan?.deleteCount, "cat sat".count)
        XCTAssertEqual(plan?.insert, "dog sat")
    }

    /// Guard against flicker: a wholesale reflow (large deleted tail) is declined
    /// so we keep the good deterministic paste and only refine history.
    func testDeclinesOversizedRewrite() {
        let pasted = String(repeating: "x", count: 200)
        let refined = "completely different short line"
        XCTAssertNil(RefinementDiff.plan(pasted: pasted, refined: refined))
    }

    /// A small rewrite right at the cap is allowed.
    func testAllowsRewriteAtCap() {
        let shared = "prefix "
        let tail = String(repeating: "a", count: RefinementDiff.maxDeleteCount)
        let plan = RefinementDiff.plan(pasted: shared + tail, refined: shared + "b")
        XCTAssertEqual(plan?.deleteCount, RefinementDiff.maxDeleteCount)
        XCTAssertEqual(plan?.insert, "b")
    }

    // MARK: caretEdit — adapts a plan to the text actually before the caret.

    private func plan(_ pasted: String, _ refined: String) -> RefinementDiff.Plan {
        guard let p = RefinementDiff.plan(pasted: pasted, refined: refined) else {
            XCTFail("expected a plan for \(pasted) -> \(refined)"); return .init(deleteCount: 0, insert: "")
        }
        return p
    }

    /// Caret sits right after our pasted text: the plan is used unchanged.
    func testCaretEditExactSuffix() {
        let pasted = "Let's meet at 3. No, wait, 4:00."
        let refined = "Let's meet at 4:00."
        let base = plan(pasted, refined)
        XCTAssertEqual(RefinementDiff.caretEdit(before: pasted, pasted: pasted, plan: base), base)
    }

    /// The real bug: TextEdit reports a trailing newline the field appended and
    /// parks the caret after it. The newline is folded into the edit — deleted
    /// with the tail and re-typed after the refined tail — so it survives.
    func testCaretEditFoldsTrailingNewline() {
        let pasted = "Let's meet at 3. No, wait, 4:00."
        let refined = "Let's meet at 4:00."
        let base = plan(pasted, refined)
        // Field value before caret is our text plus a trailing "\n".
        let edit = RefinementDiff.caretEdit(before: pasted + "\n", pasted: pasted, plan: base)
        XCTAssertEqual(edit?.deleteCount, base.deleteCount + 1)
        XCTAssertEqual(edit?.insert, base.insert + "\n")
    }

    /// Pre-caret text that isn't our pasted text (the user has other content and
    /// the caret is elsewhere) is refused outright.
    func testCaretEditRefusesForeignText() {
        let base = plan("hello there friend", "hello friend")
        XCTAssertNil(RefinementDiff.caretEdit(before: "something else entirely", pasted: "hello there friend", plan: base))
    }
}
