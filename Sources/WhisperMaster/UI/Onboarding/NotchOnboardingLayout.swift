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
    /// Depth of the band below the notch: top padding 12, top bar 24, dots 5,
    /// gap 8, orb 62, gap 12, a one-line headline (~23), gap 3, a body of at most
    /// two lines (~32), gap 16, the action row (~36) and bottom padding 16. That
    /// sums to ~249, so about 15 pt spare. Copy is shortened before this grows.
    var thickness: CGFloat = 264
    /// Centre of the 62 pt band orb below the notch: 12 + 24 + 5 + 8 + 31.
    var orbCenterY: CGFloat = 80
    /// The band's hero orb. Big enough for the `large` preset's dot field to read
    /// as a sphere rather than a speckle.
    var orbDiameter: CGFloat = 62
    /// The soft glow a grant raises behind the band orb.
    var bloomSize = CGSize(width: 260, height: 120)
    /// Radius of the concave flare where the top meets the bezel. The opening
    /// stage uses the same flare, so the swap from stage to band matches.
    var topConcaveRadius: CGFloat = 14
    /// Radius of the surface's rounded bottom corners.
    var bottomCornerRadius: CGFloat = 24
    /// Body width used on notch-less displays so the surface still has presence.
    var fallbackBodyWidth: CGFloat = 180
    /// The widest the top-bar line (between back and settings) may run, on one line.
    var topBarLineMaxWidth: CGFloat = 260

    // The opening stage that folds into the band. Its panel is
    // `min(stageWidth, screenWidth − 56)` × `(notchHeight + stageDepth)`.
    var stageWidth: CGFloat = 640
    var stageDepth: CGFloat = 420
    var stageBottomRadius: CGFloat = 40
    var stageOrbDiameter: CGFloat = 150
    /// Below the notch, like `orbCenterY`. The orb rises from here to `orbCenterY`.
    var stageOrbCenterY: CGFloat = 172
    var stageWordmarkY: CGFloat = 300
    var stageTaglineY: CGFloat = 340
    /// The stage keeps this far from each edge of a narrow display.
    var stageScreenInset: CGFloat = 28

    /// The measure a body is fitted to: the band's text width less 5%, the same
    /// width the copy fit tests use, so the band and the tests pick the same line.
    var bodyFitWidth: CGFloat {
        (contentWidth - 2 * Theme.Space.xl - 2 * Theme.Space.lg) * 0.95
    }

    /// The opening stage's panel: fixed for the stage's life.
    func stagePanelSize(for geometry: NotchGeometry) -> CGSize {
        let width = geometry.screenWidth > 0
            ? min(stageWidth, geometry.screenWidth - 2 * stageScreenInset)
            : stageWidth
        return CGSize(width: width, height: geometry.notchHeight + stageDepth)
    }

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
