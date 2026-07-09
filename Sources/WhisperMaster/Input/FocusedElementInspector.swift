import ApplicationServices

/// Best-effort check of where the system keyboard focus is, used to decide —
/// before we synthesize keystrokes — whether auto-pasted text would actually
/// land in a text field or vanish into the void.
///
/// **Conservative by design.** `noEditableTarget()` returns `true` only when
/// we're confident there is nowhere to type: no focused element at all, or a
/// focused element whose role is clearly not a text input (a button, a window,
/// a Finder list, etc.). Anything ambiguous — a web area, a custom control, an
/// unreadable element — returns `false`, so a paste that *would* have worked is
/// never wrongly flagged as lost. Requires Accessibility trust; callers already
/// gate on it.
enum FocusedElementInspector {
    /// True only when we're confident no editable text element holds focus.
    static func noEditableTarget() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)

        guard result == .success, let focused else {
            // `.noValue` / `.attributeUnsupported` mean nothing is focused — a
            // confident "no target". Any other error is ambiguous, so we don't
            // warn (better to let the keystrokes fly than cry wolf).
            return result == .noValue || result == .attributeUnsupported
        }

        return isConfidentlyNonEditable(focused as! AXUIElement)
    }

    /// True only when a focused element with a clearly non-text role (a button,
    /// checkbox, slider, …) holds focus. Unlike `noEditableTarget()`, this is
    /// `false` when **nothing** is focused or focus is unreadable/ambiguous (web
    /// areas, Electron views) — so callers still attempt a ⌘V paste there, the
    /// case Accessibility can't see but a real paste handles fine.
    static func focusIsConfidentlyNonEditable() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused
        else { return false }
        return isConfidentlyNonEditable(focused as! AXUIElement)
    }

    /// The focused element **only when it's a confidently editable, AX-readable
    /// text target** (a settable value, or a text-field/area/combo role). This is
    /// the case where per-character typing works *and* the in-place refiner can
    /// later find and edit the text — i.e. native fields. Returns `nil` for web /
    /// Electron / unreadable focus, where the caller should paste via ⌘V instead.
    static func editableTarget() -> AXUIElement? {
        guard let element = focusedElement() else { return nil }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return element
        }
        if let role = stringAttribute(element, kAXRoleAttribute),
           role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole {
            return element
        }
        return nil
    }

    /// Compact, read-only description of the focused element for diagnostics —
    /// its role plus which text-editing affordances it exposes. Lets us see, after
    /// the fact, exactly why a paste took the native / web / nowhere route, so the
    /// "nowhere to type" classifier can be built from real data instead of guesses.
    static func focusDiagnostic() -> String {
        guard let element = focusedElement() else { return "role=none" }
        let role = stringAttribute(element, kAXRoleAttribute) ?? "unreadable"
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let hasValue = stringValue(of: element) != nil
        let hasRange = selectedRange(of: element) != nil
        return "role=\(role) settable=\(settable.boolValue ? 1 : 0)"
            + " value=\(hasValue ? 1 : 0) selRange=\(hasRange ? 1 : 0)"
    }

    private static func isConfidentlyNonEditable(_ element: AXUIElement) -> Bool {
        // A settable value means we can type here → definitely a target.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return false
        }

        guard let role = stringAttribute(element, kAXRoleAttribute) else {
            return false // can't read the role → ambiguous → don't warn
        }

        switch role {
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole:
            return false // editable text input
        case kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
             kAXPopUpButtonRole, kAXMenuButtonRole, kAXMenuItemRole,
             kAXImageRole, kAXStaticTextRole, kAXSliderRole:
            return true // an interactive non-text control clearly holds focus
        default:
            // Everything else is ambiguous → attempt the paste. Container roles
            // (scroll area, window, list, table, outline, web area) are commonly
            // what Electron / browser / custom-UI apps report *while the real
            // editable field is focused* — flagging them "no target" wrongly
            // blocked a paste that actually works, so we no longer do.
            return false
        }
    }

    /// The element that currently holds keyboard focus, if any.
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused
        else { return nil }
        return (focused as! AXUIElement)
    }

    /// True when `element` is still the system's focused element — an identity
    /// check (not value equality) so an in-place refine only ever edits the exact
    /// field it pasted into.
    static func isFocused(_ element: AXUIElement) -> Bool {
        guard let current = focusedElement() else { return false }
        return CFEqual(current, element)
    }

    /// The element's selected-text range in UTF-16 offsets, when it exposes one.
    /// A collapsed range (`length == 0`) at the value's end means the caret sits
    /// right after everything we typed — the only state where synthesized
    /// backspaces walk back over our own text rather than the user's.
    static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value
        else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    /// The element's text content, when it exposes one as a string.
    static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
