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

/// How wide the black surface is drawn, chosen by what the band is holding. The
/// notch opens as a badge, widens for a banner, and widens again to give the
/// rolling transcript room to read.
enum NotchSurfaceWidth {
    /// Just the orb, or a single-glyph beat like the delivered checkmark.
    case glyph
    /// A banner: icon, headline, sub-line, sometimes a button.
    case banner
    /// The rolling transcript, which needs real reading width.
    case transcript
}

/// Design constants and sizing math for the black surface that wraps the notch.
///
/// All the tunable numbers live here so the view and window stay declarative.
struct NotchSurfaceLayout {
    /// Wings for a band holding nothing but the orb — a small badge hugging the
    /// notch, so a lone orb isn't marooned in a wide empty band.
    var glyphSideExtension: CGFloat = 34
    /// Wings for a banner (the default, and what every hint is written against).
    var sideExtension: CGFloat = 96
    /// Wings for the rolling transcript. The banner width fits only a few words,
    /// so this is wider — and it applies only while there is text to read. Kept
    /// well short of the menu-bar edges: three lines carry the length, so the
    /// surface doesn't have to.
    var transcriptSideExtension: CGFloat = 190
    /// Thickness of the band below the notch that holds the content — sized to
    /// give the dictation orb breathing room without clipping its dots, so it
    /// tracks `NotchTranscriptRow.orbDiameter` and matches a one-line transcript.
    var bottomThickness: CGFloat = NotchTranscriptRow.orbDiameter + NotchTranscriptRow.verticalPadding * 2
    /// Band used for a failed dictation: an icon plus a short reason line, so it
    /// needs about as much room as the reminder band.
    var failedThickness: CGFloat = 44
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
    /// Band for the "smart cleanup is ready" confirmation — same footprint as the
    /// learned hint. (≤ bannerThickness, so `panelSize` already accommodates it.)
    var cleanupReadyThickness: CGFloat = 52
    /// Band for the "note saved / reminder set" confirmation after a spoken
    /// command routed into Notes & Reminders — headline plus a short second line.
    var commandConfirmationThickness: CGFloat = 52
    /// Band for the "what's my day" answer — headline plus a next-thing line.
    /// Same footprint as the Bluetooth banner (the tallest), so `panelSize` fits it.
    var daySummaryThickness: CGFloat = 58
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

    /// Full width of the black surface — the notch body plus its wings. Narrower
    /// surfaces are centered on the notch inside the panel, which is always sized
    /// for the widest one.
    func surfaceWidth(for geometry: NotchGeometry, _ width: NotchSurfaceWidth) -> CGFloat {
        let wing: CGFloat = switch width {
        case .glyph: glyphSideExtension
        case .banner: sideExtension
        case .transcript: transcriptSideExtension
        }
        return bodyWidth(for: geometry) + wing * 2
    }

    /// Band that holds the rolling transcript, sized to `lines` rows of text — or
    /// to the orb when the transcript is still shorter than it. This is the one
    /// band whose thickness is content-driven: it grows as the lines fill, up to
    /// `NotchTranscriptModel.visibleLines`.
    func transcriptThickness(lines: Int) -> CGFloat {
        max(
            NotchTranscriptRow.orbDiameter + NotchTranscriptRow.verticalPadding * 2,
            NotchTextMetrics.blockHeight(lines: lines) + NotchTranscriptRow.verticalPadding * 2
        )
    }

    /// The tallest band the surface can ever show — what the panel has to fit.
    private var maxBandThickness: CGFloat {
        max(
            max(bottomThickness, reminderThickness),
            max(
                max(undeliveredThickness, bannerThickness),
                transcriptThickness(lines: NotchTranscriptModel.visibleLines)
            )
        )
    }

    /// Full size of the floating panel for a given geometry. Width fits the widest
    /// surface (the transcript band) and height the tallest band, so the panel
    /// never clips whichever state the notch is in.
    func panelSize(for geometry: NotchGeometry) -> CGSize {
        CGSize(
            width: surfaceWidth(for: geometry, .transcript),
            height: geometry.notchHeight + maxBandThickness
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
