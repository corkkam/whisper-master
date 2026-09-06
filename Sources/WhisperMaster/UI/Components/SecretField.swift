import AppKit
import SwiftUI

/// A password field that does **not** invite macOS AutoFill — which is what kept
/// crashing the app from the Settings window.
///
/// SwiftUI's `SecureField` becomes an `NSSecureTextField`, and AppKit ships that class
/// with `contentType == .password`. That opts the field into AutoFill, so macOS attaches
/// its completion list: an *out-of-process* view (SafariPlatformSupport's
/// `SPCompletionListServiceViewController`) wrapped in an `NSRemoteView` living in the
/// field's window. The remote view outlives the connector sheet it was summoned from,
/// and once it has lost its containing window it still answers window-ordering
/// notifications. `NSPopover` attaches itself with `addChildWindow:`, which makes AppKit
/// rebuild the parent's entire window ordering group and re-order every window in it —
/// the orphan included — and it then trips its own assertion:
///
/// ```
/// -[NSRemoteView containingWindowWillOrderOnScreen:] assertion failed:
///   '<NSRemoteView … SPCompletionListServiceViewController> notified of
///    <_NSPopoverWindow …> but expected (null)'
/// ```
///
/// The exception escapes `NSHostingView.layout`, AppKit answers it with
/// `+[NSApplication _crashOnException:]`, and the process dies on `EXC_BREAKPOINT`.
/// Typing a connector secret and later opening the sidebar account popover — or the
/// assistant-help popover on the Notes tab — was the whole recipe.
///
/// Setting `contentType` to nil is AppKit's documented opt-out, and it is the right
/// answer on the merits too: these fields hold a Slack bot token or a Notion integration
/// secret, and a list of saved *website* passwords was never a useful suggestion for one.
///
/// Only the secret fields need this. A plain `NSTextField` already has a nil
/// `contentType`, so it never summons the completion list in the first place.
struct SecretField: View {
    let placeholder: String
    @Binding var text: String
    /// Point size, matched to the `Typography.sans(13)` the sibling `TextField`s use.
    var size: CGFloat = 13

    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            // `ImageRenderer` can't draw an `NSViewRepresentable` — static stand-in,
            // the same trade `VocabularyEditor`'s add field makes.
            Text(placeholder)
                .font(Typography.sans(size))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Bridge(placeholder: placeholder, text: $text, size: size)
        }
    }
}

private struct Bridge: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let size: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NoAutoFillSecureTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        // Match `.textFieldStyle(.plain)`: the surrounding SwiftUI supplies the
        // padding, fill and border, so the control itself draws nothing.
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.font(size)
        field.textColor = NSColor(Theme.textPrimary)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.text = $text
        // Guard both writes: assigning unconditionally would fight the user's typing
        // by resetting the insertion point on every SwiftUI update.
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    /// `NSSecureTextField` sizes itself to its content, so without this it would refuse
    /// to fill the form row the way the `TextField` beside it does.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSecureTextField, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? intrinsic.width, height: intrinsic.height)
    }

    /// The brand body face, resolved exactly the way `Typography.sans` does so a missing
    /// font file falls back to the same system face rather than to a different one.
    private static func font(_ size: CGFloat) -> NSFont {
        NSFont(name: BrandFont.body, size: size) ?? .systemFont(ofSize: size)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Pins the AutoFill opt-out rather than merely setting it once.
///
/// AppKit re-derives `contentType` for a secure field as it's configured and as it moves
/// between windows, so a single assignment in `makeNSView` is not something we could rely
/// on staying put. Overriding the getter is the only form of "never" available here.
private final class NoAutoFillSecureTextField: NSSecureTextField {
    override var contentType: NSTextContentType? {
        get { nil }
        set { /* deliberately ignored — see `SecretField` */ }
    }
}
