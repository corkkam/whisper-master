import Foundation

/// Computes the minimal keystroke edit that turns already-pasted text into its
/// refined version, given the hard constraint that we can only edit from the
/// caret backward: the caret sits at the very end of what we typed, so the edit
/// is always "delete the differing tail, retype it."
///
/// Pure and deterministic so the diff logic can be unit-tested without any
/// Accessibility / event-synthesis machinery.
enum RefinementDiff {
    /// A suffix rewrite: backspace `deleteCount` characters from the end of the
    /// pasted text, then type `insert`.
    struct Plan: Equatable {
        let deleteCount: Int
        let insert: String
    }

    /// Largest tail we'll delete-and-retype in place. Beyond this the visible
    /// backspacing reads as a glitch, so we leave the (already good)
    /// deterministic paste untouched — the polish still lands in history.
    static let maxDeleteCount = 80

    /// The edit to apply, or `nil` when the texts are identical or the differing
    /// tail is too large to rewrite without visible flicker. Works in Character
    /// (grapheme) units, matching how a text field consumes one backspace.
    static func plan(pasted: String, refined: String) -> Plan? {
        guard pasted != refined else { return nil }
        let p = Array(pasted)
        let r = Array(refined)
        var i = 0
        let shared = min(p.count, r.count)
        while i < shared, p[i] == r[i] { i += 1 }
        let deleteCount = p.count - i
        guard deleteCount <= maxDeleteCount else { return nil }
        return Plan(deleteCount: deleteCount, insert: String(r[i...]))
    }

    /// Adapt a base `plan` to what's actually before the caret.
    ///
    /// Backspaces remove the characters immediately before the caret, so the
    /// pre-caret text must be exactly what we pasted. Text fields often park a
    /// trailing newline *after* the caret that we never typed — but some report
    /// it *before* the caret; when they do, that whitespace is folded into the
    /// edit (deleted with the tail, re-typed after the refined tail) so the
    /// field's own newline survives. Returns `nil` when the pre-caret text isn't
    /// our pasted text at all (someone else's content — refuse to edit).
    static func caretEdit(before: String, pasted: String, plan: Plan) -> Plan? {
        if before.hasSuffix(pasted) { return plan }
        let chars = Array(before)
        var end = chars.count
        while end > 0, chars[end - 1].isWhitespace { end -= 1 }
        let trailing = String(chars[end...])
        guard !trailing.isEmpty, String(chars[0..<end]).hasSuffix(pasted) else { return nil }
        return Plan(deleteCount: plan.deleteCount + trailing.count, insert: plan.insert + trailing)
    }
}
