import AppKit

/// Sizing for the onboarding band that hangs out of the notch.
///
/// The dictation surface (`NotchSurfaceLayout`) sizes itself to whichever state
/// it's holding and stays deliberately slim; onboarding is a read-and-decide
/// surface, so it gets one fixed, roomier body. Same molded `NotchShape`, same
/// top-center anchoring — all the numbers live here so the view and window stay
/// declarative.
struct NotchOnboardingLayout {
    /// Width of the black body. Wide enough for a headline on one line and a
    /// button beneath it, and kept well inside the menu-bar edges.
    var contentWidth: CGFloat = 460
    /// Smallest wing either side of the notch, so the surface always reads as
    /// flowing out of the notch rather than as a slab that happens to touch it.
    var minSideExtension: CGFloat = 70
    /// Depth of the band below the notch: top row, dots, orb, two lines of copy
    /// and the action row.
    var thickness: CGFloat = 234
    /// Radius of the concave flare where the top meets the bezel.
    var topConcaveRadius: CGFloat = 14
    /// Radius of the surface's rounded bottom corners.
    var bottomCornerRadius: CGFloat = 24
    /// Body width used on notch-less displays so the surface still has presence.
    var fallbackBodyWidth: CGFloat = 180

    /// Full width of the black surface — the notch body plus its wings, or the
    /// content width when that's wider (which it is on every real display).
    func surfaceWidth(for geometry: NotchGeometry) -> CGFloat {
        let body = geometry.hasNotch ? geometry.notchWidth : fallbackBodyWidth
        return max(contentWidth, body + minSideExtension * 2)
    }

    /// Full size of the floating panel. Unlike the dictation pill this is sized
    /// exactly to the surface — the band never changes shape mid-flow, so there's
    /// no widest-state allowance to make.
    func panelSize(for geometry: NotchGeometry) -> CGSize {
        CGSize(width: surfaceWidth(for: geometry), height: geometry.notchHeight + thickness)
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
