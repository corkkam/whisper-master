import ApplicationServices
import Foundation

/// Rewrites already-pasted dictation in place when the optional on-device polish
/// lands a beat after the deterministic text was typed.
///
/// Dictation pastes the deterministic cleanup *instantly* so it never waits on
/// the LLM. The qwen polish then runs in the background; when it produces a
/// better version, this replaces what we typed so the field ends up as clean as
/// if we'd waited, but the user never did.
///
/// Two rewrite mechanisms, picked by how big the change is:
///  - **Small trailing edit** (a self-correction near the end): backspace over
///    the differing tail and retype it. Minimal, no clipboard, no selection.
///  - **Large / reordered rewrite** (qwen reflowed the whole sentence): select
///    exactly the region we pasted (Shift+Left arrows) and *type* the refined
///    text over the selection — typing replaces a selection in every text field.
///    Handles reordering a suffix diff can't, reuses the proven injection path,
///    and avoids both the clipboard and the unreliable AX "set selected text"
///    (which some fields, e.g. TextEdit, accept then silently ignore).
///
/// **Safety is everything here.** All paths refuse unless the same element still
/// has focus, the caret is a collapsed insertion point, and the text immediately
/// before the caret is exactly what we pasted — so we only ever touch our own
/// characters, never something the user typed after us.
@MainActor
enum InPlaceRefiner {
    /// Attempt to rewrite the pasted text to `refined` in `element`. Returns
    /// `true` only if it was safe and the edit was performed; `false` (caller
    /// keeps the deterministic paste on screen) otherwise.
    static func apply(
        pasted: String,
        refined: String,
        element: AXUIElement,
        injector: TextInjector
    ) async -> Bool {
        // The exact field we pasted into must still hold focus, with a collapsed
        // caret and a readable value.
        guard FocusedElementInspector.isFocused(element) else { return false }
        guard let range = FocusedElementInspector.selectedRange(of: element),
              range.length == 0,
              let value = FocusedElementInspector.stringValue(of: element)
        else { return false }

        let units = Array(value.utf16)
        let caret = range.location
        guard caret >= 0, caret <= units.count else { return false }
        let before = string(fromUTF16: units, upTo: caret)

        // Small trailing edit → fast backspace-retype at the caret.
        if let plan = RefinementDiff.plan(pasted: pasted, refined: refined),
           let edit = RefinementDiff.caretEdit(before: before, pasted: pasted, plan: plan) {
            await injector.deleteBackward(edit.deleteCount)
            if !edit.insert.isEmpty { await injector.inject(edit.insert) }
            return true
        }

        // Large / reordered rewrite → select the pasted region and type over it.
        // Peel off any trailing whitespace the field parked after our text, then
        // confirm what's left really ends with what we pasted.
        let chars = Array(before)
        var end = chars.count
        while end > 0, chars[end - 1].isWhitespace { end -= 1 }
        let trailing = chars.count - end
        guard String(chars[0..<end]).hasSuffix(pasted) else { return false }

        return await replaceViaSelectType(
            element: element, injector: injector,
            deselectTrailing: trailing, selectLength: pasted.count, text: refined)
    }

    // MARK: - Whole-region replace

    /// Collapse the caret to the end of our pasted text (`deselectTrailing`
    /// Lefts), select the pasted region (`selectLength` Shift+Lefts), then type
    /// `text` over the selection (typing replaces a selection). Returns whether
    /// the field now contains `text`.
    private static func replaceViaSelectType(
        element: AXUIElement, injector: TextInjector,
        deselectTrailing: Int, selectLength: Int, text: String
    ) async -> Bool {
        guard selectLength > 0 else { return false }
        if deselectTrailing > 0 { await injector.moveLeft(deselectTrailing, selecting: false) }
        await injector.moveLeft(selectLength, selecting: true)
        await injector.inject(text)
        try? await Task.sleep(nanoseconds: 80_000_000)
        return FocusedElementInspector.stringValue(of: element)?.contains(text) ?? false
    }

    private static func string(fromUTF16 units: [UInt16], upTo count: Int) -> String {
        guard count > 0 else { return "" }
        return Array(units[0..<count]).withUnsafeBufferPointer {
            String(utf16CodeUnits: $0.baseAddress!, count: $0.count)
        }
    }
}
