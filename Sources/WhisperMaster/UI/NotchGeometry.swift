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
    /// Width of the display the surface is drawn on, so the wide dictation band
    /// can be held inside the screen. Zero means "unknown" — no clamp applied.
    let screenWidth: CGFloat

    /// Whether the display actually has a notch.
    var hasNotch: Bool { notchHeight > 0 }

    /// A notch-less geometry with a sensible dead-zone height for fallback layouts.
    static let none = NotchGeometry(notchWidth: 0, notchHeight: 0, screenWidth: 0)

    /// Resolve the notch geometry for a screen.
    ///
    /// The notch width is the gap between the two usable menu-bar areas that
    /// flank it; `safeAreaInsets.top` gives its height.
    static func measure(_ screen: NSScreen) -> NotchGeometry {
        let inset = screen.safeAreaInsets.top
        guard inset > 0 else {
            // No notch, but the screen width still bounds the wide band.
            return NotchGeometry(notchWidth: 0, notchHeight: 0, screenWidth: screen.frame.width)
        }

        let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
        let width = screen.frame.width - leftWidth - rightWidth

        return NotchGeometry(
            notchWidth: max(0, width),
            notchHeight: inset,
            screenWidth: screen.frame.width
        )
    }
}

/// How wide the black surface is drawn, chosen by what the band is holding. The
/// notch opens as a badge, widens for a banner, and opens all the way out into
/// the long dictation bar.
enum NotchSurfaceWidth {
    /// A single-glyph beat — the delivered checkmark.
    case glyph
    /// A banner: icon, headline, sub-line, sometimes a button.
    case banner
    /// The dictation bar: the state on the left, the orb on the right, and the
    /// transcript rolling by between them. Long, so the words have room to read
    /// and the two ends read as two ends.
    case wide
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
    /// Wings for the dictation bar — the state at one end, the orb at the other.
    /// Sized to the *longest state word* ("Dictating (hands-free)") plus
    /// `NotchTranscriptRow.horizontalPadding`, not to a sentence of transcript: the
    /// band no longer streams the live words, so anything wider is empty black.
    var wideSideExtension: CGFloat = 190
    /// Smallest gap left between the wide bar and each screen edge, so it reads as
    /// a bar laid on the menu bar rather than one jammed against the corners.
    var wideScreenInset: CGFloat = 28
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
    /// Band for a reminder that has come due — its title plus the body (or the
    /// time it was set for). Same footprint as the other two-line hints.
    var dueReminderThickness: CGFloat = 52
    /// Band for the "what's my day" answer — headline plus a next-thing line.
    /// Same footprint as the Bluetooth banner (the tallest), so `panelSize` fits it.
    var daySummaryThickness: CGFloat = 58
    /// Radius of the concave flare where the top meets the bezel.
    var topConcaveRadius: CGFloat = 12
    /// Radius of the surface's rounded bottom corners.
    var bottomCornerRadius: CGFloat = 14
    /// Body width used on notch-less displays so the surface still has presence.
    var fallbackBodyWidth: CGFloat = 180
    /// Row height used on notch-less displays, where there is no safe-area inset to
    /// borrow. The system menu bar is 22pt; a hair more keeps the content off both
    /// edges without reading as a band.
    var fallbackRowThickness: CGFloat = 26

    /// Height of the menu-bar row — the strip the dictation status sits *in* rather
    /// than below.
    ///
    /// On a notched display this is the safe-area inset (37.5pt on the built-in
    /// Retina displays), which is exactly the height of the menu bar beside the
    /// camera housing. That is what makes the status line read as part of the menu
    /// bar instead of an overlay laid on top of it.
    func rowThickness(for geometry: NotchGeometry) -> CGFloat {
        geometry.hasNotch ? geometry.notchHeight : fallbackRowThickness
    }

    /// Orb diameter for the notch row, sized to leave a hairline of breathing room
    /// inside it. The band below the notch has room for the full
    /// `NotchTranscriptRow.orbDiameter`; the row does not.
    func rowOrbDiameter(for geometry: NotchGeometry) -> CGFloat {
        max(18, rowThickness(for: geometry) - rowVerticalPadding * 2)
    }

    /// Inset above and below the row's content — the breathing room that keeps the
    /// state word and the orb off the menu bar's own top and bottom edges.
    var rowVerticalPadding: CGFloat = 7

    /// Width of the notch body before side extensions are added.
    private func bodyWidth(for geometry: NotchGeometry) -> CGFloat {
        geometry.hasNotch ? geometry.notchWidth : fallbackBodyWidth
    }

    /// Wing wide enough for `label` at the bar's leading edge.
    ///
    /// `wideSideExtension` is sized to the longest *fixed* state word, and while
    /// those were the only captions a constant was enough. The assistant's captions
    /// carry a **user-chosen connector name** ("Checking Personal Google Calendar"),
    /// which has no bound — and in the notch-row form the leading label lives
    /// entirely in the left wing, so anything longer doesn't truncate, it slides
    /// under the camera housing and is simply not there. So the wing grows to the
    /// label instead. `surfaceWidth` still clamps the result to the screen.
    ///
    /// Measured with `NotchTextMetrics`, whose font is a half-step lighter than
    /// `Typography.notchLabel` (medium vs bold at the same 13pt) — hence
    /// `stateLabelSlack`, which covers the weight difference and keeps the last
    /// character off the housing rather than flush against it.
    func wideWing(forStateLabel label: String) -> CGFloat {
        guard !label.isEmpty else { return wideSideExtension }
        let needed = NotchTextMetrics.width(label)
            + NotchTranscriptRow.horizontalPadding
            + stateLabelSlack
        return min(maxStateLabelWing, max(wideSideExtension, ceil(needed)))
    }

    /// Headroom on a measured state label: the bold/medium weight difference plus a
    /// little air, so a caption sized exactly to its wing doesn't read as jammed
    /// against the camera housing.
    var stateLabelSlack: CGFloat = 16

    /// Ceiling on the grown wing, and therefore on the whole bar.
    ///
    /// Two things need this bound rather than letting the label decide. `panelSize`
    /// has to be computed before any caption exists, and a band wider than its panel
    /// is clipped by the window; and the panel takes clicks while a banner is up, so
    /// a bar that grew toward screen-wide would start swallowing menu-bar clicks
    /// either side of the notch.
    ///
    /// 300pt is measured, not guessed: the longest caption a real connection
    /// produces is around "Checking Personal Google Calendar" (223pt), which needs
    /// `horizontalPadding` + `stateLabelSlack` on top. Past this the label truncates
    /// against `rowLabelMaxWidth` — legibly, with an ellipsis — instead of sliding
    /// under the camera housing.
    var maxStateLabelWing: CGFloat = 300

    /// Width the leading state label may occupy in the **notch-row** form, where the
    /// content sits in the wings either side of the camera housing. Without this the
    /// label is only bounded by the whole surface, so an over-long caption doesn't
    /// truncate — it runs into the region the housing physically covers and the tail
    /// of it simply isn't there.
    func rowLabelMaxWidth(for geometry: NotchGeometry, wing: CGFloat) -> CGFloat {
        max(40, wing - NotchTranscriptRow.horizontalPadding)
    }

    /// Full width of the black surface — the notch body plus its wings. Narrower
    /// surfaces are centered on the notch inside the panel, which is always sized
    /// for the widest one.
    ///
    /// `stateLabel` only affects `.wide`, and only upward: pass the caption the bar
    /// is carrying so a long one widens the band rather than running under the
    /// camera housing. Omit it (the default) for a call that is asking about the
    /// bar's *base* width — `panelSize` and the transcript wrap both do, because the
    /// panel must be sized for a state that hasn't happened yet and the wrap must
    /// not re-flow every time the caption changes.
    func surfaceWidth(for geometry: NotchGeometry,
                      _ width: NotchSurfaceWidth,
                      stateLabel: String = "") -> CGFloat {
        let wing: CGFloat = switch width {
        case .glyph: glyphSideExtension
        case .banner: sideExtension
        case .wide: wideWing(forStateLabel: stateLabel)
        }
        let full = bodyWidth(for: geometry) + wing * 2
        // The bar is the only surface long enough to run off a small display, so
        // it's the only one the screen width bounds.
        guard width == .wide, geometry.screenWidth > 0 else { return full }
        return min(full, max(bodyWidth(for: geometry), geometry.screenWidth - wideScreenInset * 2))
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
            max(
                max(bottomThickness, reminderThickness),
                max(
                    max(undeliveredThickness, bannerThickness),
                    transcriptThickness(lines: NotchTranscriptModel.visibleLines)
                )
            ),
            // The agent panel is the tallest band the surface can carry: a choice
            // card stacks its options, because they are model-authored sentences
            // rather than three fixed words.
            max(
                max(NotchAgentPanel.maxThickness, NotchAgentGlance.maxThickness),
                NotchAgentReplyExpanded.maxThickness
            )
        )
    }

    /// Full size of the floating panel for a given geometry. Width fits the widest
    /// surface the bar can ever reach and height the tallest band, so the panel never
    /// clips whichever state the notch is in.
    ///
    /// The width is computed from `maxStateLabelWing`, not from `wideSideExtension`:
    /// the panel is sized once, at window creation, and the bar grows past the base
    /// wing whenever the assistant names a connector. Sizing it to the base would
    /// clip exactly the captions this exists to show.
    func panelSize(for geometry: NotchGeometry) -> CGSize {
        CGSize(
            width: surfaceWidth(for: geometry, .wide, stateLabel: Self.widestLabelProbe),
            height: geometry.notchHeight + maxBandThickness
        )
    }

    /// A string guaranteed to measure past `maxStateLabelWing`, so `surfaceWidth`
    /// returns the capped maximum. Cheaper and harder to get wrong than a second
    /// code path through the same clamping.
    private static let widestLabelProbe = String(repeating: "M", count: 64)

    /// Top-center origin (AppKit bottom-left coordinates) on a screen.
    func panelOrigin(for geometry: NotchGeometry, on screen: NSScreen) -> CGPoint {
        let size = panelSize(for: geometry)
        return CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
    }
}
