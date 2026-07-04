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
             kAXImageRole, kAXStaticTextRole, kAXSliderRole,
             kAXWindowRole, kAXScrollAreaRole, kAXOutlineRole,
             kAXTableRole, kAXListRole:
            return true // focus is somewhere text can't go
        default:
            return false // unknown (web view / custom) → ambiguous → don't warn
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
