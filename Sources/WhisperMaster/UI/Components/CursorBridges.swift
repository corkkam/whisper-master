import AppKit
import SwiftUI

// MARK: - Cursor + tooltip bridges to AppKit
//
// Three small `NSViewRepresentable`s that exist because the SwiftUI API for the
// same job misbehaves inside this app's windows. Each one records *which* API was
// rejected and why, so the next reader doesn't "simplify" it back into a bug.
//
// The common thread: the pill, notch and onboarding surfaces are borderless
// `.nonactivatingPanel`s whose content is hover-tracked. Cursor and tooltip work
// driven from SwiftUI's `.onHover` fights with SwiftUI's own tracking areas;
// AppKit's window-level cursor rects and `NSView.toolTip` do not.

/// Shows the pointing-hand cursor over its frame, via AppKit's **cursor rects**.
///
/// Rejected alternative: `NSCursor.pointingHand.push()` / `.pop()` inside
/// `.onHover`. Cursor rects are managed by the window and recalculated on
/// `resetCursorRects`, so they can't get out of balance; a push/pop pair keyed off
/// `.onHover` leaks a pushed cursor whenever the pointer leaves fast enough that
/// the exit callback is coalesced away, and the whole app is left with a hand.
///
/// Overlaid, never wrapped, so it can't affect layout — and hit-testing passes
/// straight through, so the control underneath keeps every click.
struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorRectView(cursor: .pointingHand) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-registers the rect after a resize — the frame it covers changed.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

/// Shows the I-beam (text selection) cursor over its frame. Same cursor-rect
/// mechanism, same reasoning, for text wells whose editor is an AppKit view.
struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorRectView(cursor: .iBeam) }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

/// A view that owns one cursor rect over its whole bounds and is otherwise
/// invisible and untouchable. `hitTest` returning `nil` is load-bearing: without
/// it this view would swallow the clicks meant for the control it sits over,
/// while cursor rects — registered with the *window* — keep working regardless.
private final class CursorRectView: NSView {
    private let cursor: NSCursor

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Attaches a native macOS tooltip through `NSView.toolTip`.
///
/// Rejected alternative: SwiftUI's `.help()`. It installs its own tracking area,
/// which competes with the `.onHover` the button ladder uses for hover state —
/// the symptom is a hover highlight that sticks after the pointer leaves. This
/// bridge is independent of hover tracking, and gets macOS's own tooltip timing
/// and placement for free.
struct NativeTooltipView: NSViewRepresentable {
    let text: String?

    func makeNSView(context: Context) -> NSView {
        let view = TooltipView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }

    /// Tooltips are delivered by the tracking rect AppKit installs for
    /// `toolTip`, which does not need hit-testing — so this stays click-through
    /// like the cursor views.
    private final class TooltipView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// The shared pointing-hand treatment for anything clickable.
    ///
    /// Disabled controls keep the arrow — a hand over a dead control is a lie
    /// about what will happen. That is read from `\.isEnabled` rather than passed
    /// in, so `.pointerCursor()` on a view that is later `.disabled(…)` is
    /// automatically right; `isEnabled:` is only for callers that already know
    /// (the button ladder does) or need to force it off.
    ///
    /// Every rung of the button ladder applies this already; reach for it
    /// directly on the custom-drawn rows and cards that use `.buttonStyle(.plain)`.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        modifier(PointerCursor(isEnabledByCaller: isEnabled))
    }

    /// The I-beam treatment for a text well.
    func iBeamCursor() -> some View {
        modifier(AppKitOverlay(isActive: true) { IBeamCursorView() })
    }

    /// A native tooltip that coexists with `.onHover`. Prefer this over `.help()`
    /// anywhere the control also tracks hover — and note a tooltip is never a
    /// substitute for an accessibility label, only an addition to one.
    func nativeTooltip(_ text: String?) -> some View {
        modifier(AppKitOverlay(isActive: text != nil) { NativeTooltipView(text: text) })
    }
}

/// The pointing-hand overlay, gated on both the caller's intent and the live
/// `\.isEnabled` state.
private struct PointerCursor: ViewModifier {
    let isEnabledByCaller: Bool

    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.modifier(
            AppKitOverlay(isActive: isEnabledByCaller && isEnabled) { PointerCursorView() }
        )
    }
}

/// Hangs an inert AppKit view over the content — and **omits it entirely under
/// the headless snapshot renderer.**
///
/// `ImageRenderer` cannot draw `NSViewRepresentable`, so anything wrapping one is
/// substituted with a red "unsupported" placeholder. Since these overlays cover
/// their whole frame, leaving them in blanks out every button in every snapshot
/// PNG (which is exactly what happened the first time). None of the three does
/// anything a still image could show, so skipping them under `isSnapshot` costs
/// nothing and keeps the fast UI loop usable.
private struct AppKitOverlay<Bridge: View>: ViewModifier {
    let isActive: Bool
    @ViewBuilder let bridge: Bridge

    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        content.overlay {
            if isActive, !isSnapshot {
                bridge.allowsHitTesting(false)
            }
        }
    }
}
