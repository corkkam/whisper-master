import AppKit

/// Measured geometry of a single display's notch (or its absence).
///
/// Pure value type — derived once from an `NSScreen` and handed to the view
/// layer so the UI never has to reach back into AppKit to lay itself out.
struct NotchGeometry: Equatable {
    /// Width of the physical notch (camera housing). Zero on notch-less displays.
    let notchWidth: CGFloat
    /// Height of the notch, i.e. the top safe-area inset. Zero when absent.
    let notchHeight: CGFloat

    /// Whether the display actually has a notch.
    var hasNotch: Bool { notchHeight > 0 }

    /// A notch-less geometry with a sensible dead-zone height for fallback layouts.
    static let none = NotchGeometry(notchWidth: 0, notchHeight: 0)

    /// Resolve the notch geometry for a screen.
    ///
    /// The notch width is the gap between the two usable menu-bar areas that
    /// flank it; `safeAreaInsets.top` gives its height.
    static func measure(_ screen: NSScreen) -> NotchGeometry {
        let inset = screen.safeAreaInsets.top
        guard inset > 0 else { return .none }

        let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
        let width = screen.frame.width - leftWidth - rightWidth

        return NotchGeometry(notchWidth: max(0, width), notchHeight: inset)
    }
}

/// Design constants and sizing math for the black surface that wraps the notch.
///
/// All the tunable numbers live here so the view and window stay declarative.
struct NotchSurfaceLayout {
    /// How far the surface extends beyond the notch on each side — wide wings
    /// that spread well past the notch.
    var sideExtension: CGFloat = 124
    /// Thickness of the band below the notch that holds the content. Kept
    /// shallow so the surface reads as a wide, short shelf.
    var bottomThickness: CGFloat = 20
    /// Taller band used when the notch hosts the Bluetooth-mic hint (icon + text
    /// + button need more room than the thin dictation indicator).
    var bannerThickness: CGFloat = 58
    /// Band used for a gentle reminder — one short text line, between the thin
    /// indicator and the full Bluetooth banner.
    var reminderThickness: CGFloat = 32
    /// Band used for the "nowhere to paste" hint — a headline plus a short
    /// second line, so it needs about as much room as the Bluetooth banner.
    var undeliveredThickness: CGFloat = 52
    /// Band for the "learned a word" confirmation — headline plus a short second
    /// line, same footprint as the undelivered hint.
    var learnedThickness: CGFloat = 52
    /// Radius of the concave flare where the top meets the bezel.
    var topConcaveRadius: CGFloat = 12
    /// Radius of the surface's rounded bottom corners.
    var bottomCornerRadius: CGFloat = 14
    /// Body width used on notch-less displays so the surface still has presence.
    var fallbackBodyWidth: CGFloat = 180

    /// Width of the notch body before side extensions are added.
    private func bodyWidth(for geometry: NotchGeometry) -> CGFloat {
        geometry.hasNotch ? geometry.notchWidth : fallbackBodyWidth
    }

    /// Full size of the floating panel for a given geometry. Height fits the
    /// tallest band the surface can show (the banner) so the panel never clips.
    func panelSize(for geometry: NotchGeometry) -> CGSize {
        CGSize(
            width: bodyWidth(for: geometry) + sideExtension * 2,
            height: geometry.notchHeight + max(bottomThickness, max(reminderThickness, max(undeliveredThickness, bannerThickness)))
        )
    }

    /// Top-center origin (AppKit bottom-left coordinates) on a screen.
    func panelOrigin(for geometry: NotchGeometry, on screen: NSScreen) -> CGPoint {
        let size = panelSize(for: geometry)
        return CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
    }
}
