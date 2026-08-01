import AppKit

/// Sizing for the hover quick-actions panel that drops out of the notch.
///
/// Two rects, not one: the **hover zone** (the menu-bar strip over the camera
/// housing, which is what the pointer has to reach) and the **surface** (the band
/// that opens under it). The hover zone is never drawn — no panel sits over the
/// notch while the panel is closed, so nothing can intercept a menu-bar click; the
/// window polls the pointer against this rect instead. All the numbers live here so
/// the view and the window stay declarative, same as `NotchSurfaceLayout`.
struct NotchQuickActionsLayout {
    /// Slack either side of the notch body that still counts as "on the notch".
    ///
    /// Wide enough that the pointer doesn't have to be *on* the camera housing —
    /// aiming at a 10pt margin meant the panel only answered at the notch's own
    /// edges — but still well inside the wings: the menu bar's own items (the app
    /// menu on the left, the status icons and clock on the right) live further out,
    /// and a zone that reached them would open the band while someone reaches for
    /// the clock.
    var hoverSideExtension: CGFloat = 56
    /// How far *below* the menu bar still counts as reaching for the notch.
    ///
    /// The strip alone is a hairline target: the pointer decelerates into the top of
    /// the screen and comes to rest a few points under the bar as often as in it, and
    /// a hand travelling *up* toward the notch spends its last moments here. A shallow
    /// lip turns the target from a line into a block. Kept small so the zone stays a
    /// deliberate reach for the menu bar rather than a trap over window chrome.
    var approachDepth: CGFloat = 18
    /// Height of the hover zone on a notch-less display, where there is no
    /// safe-area inset to borrow. The system menu bar is 22pt.
    var fallbackHoverHeight: CGFloat = 22
    /// Width of the black body. Wide enough for two columns of short rows.
    var contentWidth: CGFloat = 452
    /// Smallest wing either side of the notch, so the surface reads as flowing out
    /// of the notch rather than as a slab that happens to touch it.
    var minSideExtension: CGFloat = 64
    /// Depth of the band for a single row of content: header, one row, action row.
    var baseThickness: CGFloat = 144
    /// What each additional row adds. Measured against the *reminder* row (title +
    /// due line), the taller of the two column shapes.
    var rowHeight: CGFloat = 36
    /// Radius of the concave flare where the top meets the bezel.
    var topConcaveRadius: CGFloat = 14
    /// Radius of the surface's rounded bottom corners.
    var bottomCornerRadius: CGFloat = 22
    /// Body width used on notch-less displays so the surface still has presence.
    var fallbackBodyWidth: CGFloat = 180
    /// Slack around the open panel that still counts as "the pointer is on it", so
    /// a hand that drifts off the edge mid-reach — rounding a corner, overshooting a
    /// row — doesn't close the panel out from under it.
    var exitMargin: CGFloat = 24

    /// The zone the pointer has to be in for the panel to open, in screen
    /// coordinates (AppKit, bottom-left origin): the notch body plus its wings,
    /// running from the top of the screen down through the menu bar and a shallow
    /// lip below it.
    ///
    /// Takes a bare frame rather than the `NSScreen` so the geometry is testable —
    /// an `NSScreen` can't be constructed under `swift test`.
    func hoverZone(for geometry: NotchGeometry, screenFrame: CGRect) -> CGRect {
        let body = geometry.hasNotch ? geometry.notchWidth : fallbackBodyWidth
        let width = body + hoverSideExtension * 2
        let strip = geometry.hasNotch ? geometry.notchHeight : fallbackHoverHeight
        let height = strip + approachDepth
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    func hoverZone(for geometry: NotchGeometry, on screen: NSScreen) -> CGRect {
        hoverZone(for: geometry, screenFrame: screen.frame)
    }

    /// Whether the pointer counts as "still on the thing" while the panel is **open**:
    /// anywhere on the band (plus `exitMargin` of slack), or still up on the notch
    /// above it. The union is what makes the reach down into the band continuous —
    /// there is no dead strip between the two where the grace has to cover for us.
    func isPointerEngaged(_ pointer: CGPoint, panelFrame: CGRect, zone: CGRect) -> Bool {
        panelFrame.insetBy(dx: -exitMargin, dy: -exitMargin).contains(pointer)
            || zone.contains(pointer)
    }

    /// Full width of the black surface — the notch body plus its wings, or the
    /// content width when that's wider (which it is on every real display).
    func surfaceWidth(for geometry: NotchGeometry) -> CGFloat {
        let body = geometry.hasNotch ? geometry.notchWidth : fallbackBodyWidth
        return max(contentWidth, body + minSideExtension * 2)
    }

    /// Depth of the band for the longer of its two columns. Content-driven, like the
    /// dictation surface's transcript band: an account with one reminder due doesn't
    /// earn a slab of empty black, and an empty one is barely a strip.
    func thickness(rows: Int) -> CGFloat {
        let rows = max(1, min(rows, NotchQuickActionsModel.columnLimit))
        return baseThickness + CGFloat(rows - 1) * rowHeight
    }

    /// Full size of the floating panel. Sized exactly to the surface — the panel is
    /// only ever on screen while open, and it's re-sized as it opens.
    func panelSize(for geometry: NotchGeometry, rows: Int) -> CGSize {
        CGSize(
            width: surfaceWidth(for: geometry),
            height: geometry.notchHeight + thickness(rows: rows))
    }

    /// Top-center origin (AppKit bottom-left coordinates) on a screen.
    func panelOrigin(for geometry: NotchGeometry, on screen: NSScreen, rows: Int) -> CGPoint {
        let size = panelSize(for: geometry, rows: rows)
        return CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
    }
}
