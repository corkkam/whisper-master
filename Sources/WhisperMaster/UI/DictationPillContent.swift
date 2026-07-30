import SwiftUI

/// The notch-anchored dictation surface.
///
/// A single black `NotchShape` wraps the physical notch — extending past it on
/// the left and right and hanging below in a thicker band that holds the
/// `DictationStatusView`. When there's something to show it extrudes downward
/// out of the notch; otherwise it retracts back up and disappears.
struct DictationPillContent: View {
    let state: AppState
    var geometry: NotchGeometry = .none
    var layout: NotchSurfaceLayout = NotchSurfaceLayout()
    /// Tap action for the command-confirmation banner — opens Settings → Notes &
    /// Reminders so a spoken reminder's default time is one click from editable.
    var onOpenNotes: () -> Void = {}
    /// Puts the transcript that couldn't be pasted on the clipboard — the Copy
    /// button on the undelivered hint. Injected so the view stays AppKit-free;
    /// the owner reads the current (possibly polished) text itself.
    var onCopyUndelivered: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A failed session gets its own taller band to fit the reason line.
    private var isFailed: Bool {
        if case .failed = state.phase { return true }
        return false
    }

    /// The "note saved / reminder set" confirmation after a spoken command routed
    /// into Notes & Reminders — highest priority, since the paste was suppressed
    /// and this is the user's only feedback that the words went somewhere.
    private var showCommandConfirmation: Bool { !showApproval && state.shouldShowCommandConfirmation }

    /// The "what's my day" answer — the immediate result of a connector query the
    /// user just asked for. Just under the command confirmation.
    private var showDaySummary: Bool { !showApproval && !showCommandConfirmation && state.shouldShowDaySummary }

    /// The "nowhere to paste" hint — the immediate consequence of a dictation
    /// that had no target field.
    /// A write awaiting consent outranks every other banner. Burying a consent card
    /// under a day summary would either lose the write to its timeout or, worse, train
    /// the user to dismiss cards they never read.
    private var showApproval: Bool { state.approvals.pending != nil }

    private var showUndelivered: Bool { !showApproval && !showCommandConfirmation && !showDaySummary && state.shouldShowUndeliveredBanner }

    /// The "learned a word" confirmation — just under the undelivered hint.
    private var showLearned: Bool { !showApproval && !showCommandConfirmation && !showDaySummary && !showUndelivered && state.shouldShowLearnedBanner }

    /// The one-shot "smart cleanup is ready" confirmation — just under the
    /// learned hint. (Model download *progress* never appears here.)
    private var showCleanupReady: Bool { !showApproval && !showCommandConfirmation && !showDaySummary && !showUndelivered && !showLearned && state.shouldShowCleanupReadyBanner }

    /// The Bluetooth-mic hint takes precedence over the dictation indicator and
    /// uses a taller band to fit its text + button.
    private var showBanner: Bool { !showApproval && !showCommandConfirmation && !showDaySummary && !showUndelivered && !showLearned && !showCleanupReady && state.shouldShowBluetoothBanner }

    /// A gentle reminder — lower priority than the hints above, shown only when
    /// idle (`AppState.shouldShowReminder` already gates that).
    private var showReminder: Bool { !showApproval && !showCommandConfirmation && !showDaySummary && !showUndelivered && !showLearned && !showCleanupReady && !showBanner && state.shouldShowReminder }

    private var bandThickness: CGFloat {
        if showApproval { return layout.bannerThickness }
        if showCommandConfirmation { return layout.commandConfirmationThickness }
        if showDaySummary { return layout.daySummaryThickness }
        if showUndelivered { return layout.undeliveredThickness }
        if showLearned { return layout.learnedThickness }
        if showCleanupReady { return layout.cleanupReadyThickness }
        if showBanner { return layout.bannerThickness }
        if showReminder { return layout.reminderThickness }
        if isFailed { return layout.failedThickness }
        // The polished line is the one band that breathes: it takes a row per
        // wrapped line, up to the three-line window.
        let model = transcriptModel
        if !model.isEmpty { return layout.transcriptThickness(lines: model.visibleLineCount) }
        return layout.bottomThickness // lone orb + delivered beat both slim
    }

    /// Whether the surface draws **in** the menu-bar row instead of in a band
    /// hanging below the notch.
    ///
    /// This is the status line's resting form: while there is nothing to read, the
    /// state word and the orb sit in the menu bar itself, on either side of the
    /// camera housing — at the notch's own height, which is what makes it read as
    /// part of the menu bar rather than an overlay laid on top of one. Since the
    /// live transcript is never shown (see `transcriptModel`), this is now the form
    /// a whole dictation is spent in; the notch only opens downward for something a
    /// band is needed for: a banner, a failure reason, a download percentage, the
    /// polished line.
    ///
    /// The wings are wider than half the notch body (190pt vs ~104pt either side),
    /// so the leading label and trailing orb land outside the camera housing
    /// without any special-casing.
    private var isNotchRow: Bool {
        guard bandIsDictation || isDeliveredBadge else { return false }
        return transcriptModel.isEmpty
    }

    private var rowThickness: CGFloat { layout.rowThickness(for: geometry) }

    private var expandedHeight: CGFloat {
        isNotchRow ? rowThickness : geometry.notchHeight + bandThickness
    }

    /// Whether one of the banners is what the band is carrying. `band` below picks
    /// them in this same order; this is the single "not the dictation indicator"
    /// test the width, thickness and glow all read from.
    private var bandIsBanner: Bool {
        showApproval || showCommandConfirmation || showDaySummary || showUndelivered
            || showLearned || showCleanupReady || showBanner || showReminder
    }

    /// Whether the band is the *transcript-bearing* dictation indicator. Narrower
    /// than "not a banner": a failure and a model download both render through
    /// `DictationStatusView` too, but each has its own width and thickness.
    private var bandIsDictation: Bool {
        !bandIsBanner && !isFailed && state.download == nil
    }

    /// What the dictation band is doing, as one named state — the value that picks
    /// the orb figure, the state word, **and** the hue the surface is lit in, so
    /// those three can't disagree.
    ///
    /// `.idle` whenever a banner is what's showing: the banners carry their own
    /// meaning and chrome, and lighting the band signal-green behind a Bluetooth
    /// warning would say two different things at once.
    /// Gated on `bandIsBanner`, not `bandIsDictation`: a failure and a download are
    /// dictation states that deserve their light (danger, and a quiet signal), even
    /// though neither carries a transcript.
    private var activity: NotchActivity {
        bandIsBanner ? .idle : NotchActivity.resolve(from: state)
    }

    /// The words the band is carrying, resolved here rather than in the row so the
    /// band's thickness and the row's line count come from the same wrap — no
    /// measurement round-trip, no one-frame lag between the two.
    ///
    /// **The live transcript is deliberately not shown.** The band reports the
    /// *state* of a dictation, never the words as they stream: reading your own
    /// speech back off the bezel pulls your eyes away from whatever you're
    /// dictating into, and the words are already landing there. So this is empty
    /// for the whole recording → finalizing → polishing stretch — which is what
    /// keeps the surface in its slim menu-bar row form (`isNotchRow`) throughout.
    ///
    /// The one exception is the finished **polished** beat: the rewrite already
    /// happened, so holding the new line for a moment is the only way the
    /// substitution isn't invisible.
    ///
    /// It is resolved at the **expanded** width unconditionally, which looks
    /// circular (the width depends on whether there's a transcript) but isn't:
    /// an empty model means the compact surface, and a non-empty one means the
    /// expanded surface, so the expanded width is the right width whenever the
    /// answer is used at all.
    private var transcriptModel: NotchTranscriptModel {
        guard bandIsDictation,
              state.shouldShowPolishedBeat,
              let polished = state.polishedText
        else { return NotchTranscriptModel() }
        return .resolve(
            confirmed: polished,
            partial: "",
            width: NotchTranscriptRow.textWidth(
                surfaceWidth: layout.surfaceWidth(for: geometry, .wide))
        )
    }

    /// Which of the three widths the current band wants. Dictation is the bar,
    /// sized to the state word it carries; the delivered checkmark stays a bare
    /// badge; every hint is written against the banner width.
    private var surfaceKind: NotchSurfaceWidth {
        guard bandIsDictation else { return .banner }
        return isDeliveredBadge ? .glyph : .wide
    }

    /// The delivered checkmark on its own — the one dictation state with nothing
    /// to read and nothing running, so it doesn't earn the bar. Mirrors
    /// `DictationStatusView`'s branch order, which puts the working states first.
    private var isDeliveredBadge: Bool {
        !state.shouldShowLiveTranscript
            && !state.shouldShowPolishedBeat
            && state.preparingEngine == nil
            && state.shouldShowDeliveredBeat
    }

    /// Width of the black surface. The panel itself is always sized for the widest
    /// state, so the surface is framed inside it and centered on the notch.
    private var surfaceWidth: CGFloat {
        layout.surfaceWidth(for: geometry, surfaceKind)
    }

    /// Whether the surface should be dropped down and visible.
    private var isExpanded: Bool {
        // Hints, the delivered beat, and the polish that runs on after a paste
        // all show even when idle.
        if showCommandConfirmation || showDaySummary || showUndelivered || showLearned || showCleanupReady || showBanner || showReminder
            || state.shouldShowDeliveredBeat || state.shouldShowLiveTranscript
            || state.shouldShowPolishedBeat { return true }
        guard hasContent else { return false }
        if state.phase == .idle && state.hidePillWhenIdle { return false }
        return true
    }

    /// Whether any state is worth surfacing at all.
    private var hasContent: Bool {
        if state.download != nil || state.preparingEngine != nil { return true }
        if state.shouldShowDeliveredBeat { return true }
        if state.shouldShowLiveTranscript || state.shouldShowPolishedBeat { return true }
        switch state.phase {
        case .recording, .preparingModels, .stopping, .failed: return true
        case .idle: return false
        }
    }

    var body: some View {
        let shape = NotchShape(
            topConcaveRadius: layout.topConcaveRadius,
            bottomCornerRadius: layout.bottomCornerRadius
        )

        Group {
            if isNotchRow {
                // Drawn *in* the menu-bar row: no dead-zone, because the content
                // lives in the wings either side of the camera housing rather than
                // below it.
                band
                    .frame(maxWidth: .infinity)
                    .frame(height: rowThickness)
            } else {
                VStack(spacing: 0) {
                    // Camera dead-zone — nothing renders behind the physical notch.
                    // Non-hittable so clicks above the band fall through to the
                    // menu bar.
                    Color.clear
                        .frame(height: geometry.notchHeight)
                        .allowsHitTesting(false)

                    band
                        .frame(maxWidth: .infinity)
                        .frame(height: bandThickness)
                }
            }
        }
        .frame(width: surfaceWidth, height: isExpanded ? expandedHeight : 0, alignment: .top)
        // Pitch-black fill molded to the physical notch, lit from inside by the
        // current state: ember while it's hearing you, signal while the machine
        // works, danger on a failure. The glow is *inside* the shape (drawn over
        // the fill, under the content) so the clip keeps it molded to the notch —
        // outside it, the light would spill past the band's rounded corners.
        .background {
            shape.fill(Theme.Notch.surface)
                .overlay { NotchGlow(activity: activity) }
                .clipShape(shape)
        }
        .clipShape(shape)
        .opacity(isExpanded ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Only the interactive banners take clicks (the Bluetooth "use built-in"
        // button, the tappable command confirmation, and the undelivered hint's
        // Copy button); the dictation indicator stays click-through (the panel
        // toggles ignoresMouseEvents to match).
        .allowsHitTesting(showApproval || showBanner || showCommandConfirmation || showUndelivered)
        // Appear *instantly* (no animation when expanding), animate only the
        // retract. A spring on the way in read as "the notch appears late" even
        // though the state flips synchronously on key-press. Banners (below) keep
        // the softer spring since they slide in inside an already-open notch.
        .animation(isExpanded ? nil : Theme.Motion.respecting(reduceMotion, Theme.Motion.retract), value: isExpanded)
        // The surface widens when the first words land and narrows when they go —
        // animated so it reads as the notch making room, not as a size jump.
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: surfaceWidth)
        // …and it deepens a row at a time as the transcript wraps onto new lines.
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.quick), value: bandThickness)
        // The notch opening out of the menu-bar row (and closing back into it) is
        // the surface's biggest move, so it gets the settle curve.
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: isNotchRow)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showUndelivered)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showLearned)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showCleanupReady)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showBanner)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showReminder)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showCommandConfirmation)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showDaySummary)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showApproval)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: state.shouldShowDeliveredBeat)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: state.shouldShowPolishedBeat)
    }

    @ViewBuilder
    private var band: some View {
        if showApproval, let approval = state.approvals.pending {
            NotchApprovalBanner(approval: approval) { outcome in
                state.approvals.resolve(outcome)
            }
        } else if showCommandConfirmation, let message = state.commandConfirmation {
            NotchCommandConfirmationBanner(message: message)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenNotes)
        } else if showDaySummary, let summary = state.activeDaySummary {
            NotchDaySummaryBanner(summary: summary)
        } else if showUndelivered {
            NotchUndeliveredBanner(text: state.undeliveredText ?? "", onCopy: onCopyUndelivered)
        } else if showLearned, let term = state.learnedTerm {
            NotchLearnedBanner(term: term)
        } else if showCleanupReady {
            NotchCleanupReadyBanner()
        } else if showBanner {
            NotchBluetoothBanner(state: state)
        } else if showReminder, let line = state.activeReminder {
            NotchReminderBanner(text: line)
        } else {
            DictationStatusView(
                state: state,
                transcript: transcriptModel,
                activity: activity,
                rowOrbSize: isNotchRow ? layout.rowOrbDiameter(for: geometry) : nil,
                rowVerticalInset: isNotchRow ? layout.rowVerticalPadding : nil
            )
        }
    }
}
