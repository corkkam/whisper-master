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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A failed session gets its own taller band to fit the reason line.
    private var isFailed: Bool {
        if case .failed = state.phase { return true }
        return false
    }

    /// The "note saved / reminder set" confirmation after a spoken command routed
    /// into Notes & Reminders — highest priority, since the paste was suppressed
    /// and this is the user's only feedback that the words went somewhere.
    private var showCommandConfirmation: Bool { state.shouldShowCommandConfirmation }

    /// The "what's my day" answer — the immediate result of a connector query the
    /// user just asked for. Just under the command confirmation.
    private var showDaySummary: Bool { !showCommandConfirmation && state.shouldShowDaySummary }

    /// The "nowhere to paste" hint — the immediate consequence of a dictation
    /// that had no target field.
    private var showUndelivered: Bool { !showCommandConfirmation && !showDaySummary && state.shouldShowUndeliveredBanner }

    /// The "learned a word" confirmation — just under the undelivered hint.
    private var showLearned: Bool { !showCommandConfirmation && !showDaySummary && !showUndelivered && state.shouldShowLearnedBanner }

    /// The one-shot "smart cleanup is ready" confirmation — just under the
    /// learned hint. (Model download *progress* never appears here.)
    private var showCleanupReady: Bool { !showCommandConfirmation && !showDaySummary && !showUndelivered && !showLearned && state.shouldShowCleanupReadyBanner }

    /// The Bluetooth-mic hint takes precedence over the dictation indicator and
    /// uses a taller band to fit its text + button.
    private var showBanner: Bool { !showCommandConfirmation && !showDaySummary && !showUndelivered && !showLearned && !showCleanupReady && state.shouldShowBluetoothBanner }

    /// A gentle reminder — lower priority than the hints above, shown only when
    /// idle (`AppState.shouldShowReminder` already gates that).
    private var showReminder: Bool { !showCommandConfirmation && !showDaySummary && !showUndelivered && !showLearned && !showCleanupReady && !showBanner && state.shouldShowReminder }

    private var bandThickness: CGFloat {
        if showCommandConfirmation { return layout.commandConfirmationThickness }
        if showDaySummary { return layout.daySummaryThickness }
        if showUndelivered { return layout.undeliveredThickness }
        if showLearned { return layout.learnedThickness }
        if showCleanupReady { return layout.cleanupReadyThickness }
        if showBanner { return layout.bannerThickness }
        if showReminder { return layout.reminderThickness }
        if isFailed { return layout.failedThickness }
        return layout.bottomThickness // live indicator + delivered beat both slim
    }

    private var expandedHeight: CGFloat {
        geometry.notchHeight + bandThickness
    }

    /// Whether the surface should be dropped down and visible.
    private var isExpanded: Bool {
        // Hints + the delivered beat show even when idle.
        if showCommandConfirmation || showDaySummary || showUndelivered || showLearned || showCleanupReady || showBanner || showReminder
            || state.shouldShowDeliveredBeat { return true }
        guard hasContent else { return false }
        if state.phase == .idle && state.hidePillWhenIdle { return false }
        return true
    }

    /// Whether any state is worth surfacing at all.
    private var hasContent: Bool {
        if state.download != nil || state.preparingEngine != nil { return true }
        if state.shouldShowDeliveredBeat { return true }
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

        VStack(spacing: 0) {
            // Camera dead-zone — nothing renders behind the physical notch.
            // Non-hittable so clicks above the band fall through to the menu bar.
            Color.clear
                .frame(height: geometry.notchHeight)
                .allowsHitTesting(false)

            band
                .frame(maxWidth: .infinity)
                .frame(height: bandThickness)
        }
        .frame(height: isExpanded ? expandedHeight : 0, alignment: .top)
        // Pitch-black fill molded to the physical notch — no sheen or lit rim.
        .background {
            shape.fill(Theme.Notch.surface)
        }
        .clipShape(shape)
        .opacity(isExpanded ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Only the interactive banners take clicks (the Bluetooth "use built-in"
        // button and the tappable command confirmation); the dictation indicator
        // stays click-through (the panel toggles ignoresMouseEvents to match).
        .allowsHitTesting(showBanner || showCommandConfirmation)
        // Appear *instantly* (no animation when expanding), animate only the
        // retract. A spring on the way in read as "the notch appears late" even
        // though the state flips synchronously on key-press. Banners (below) keep
        // the softer spring since they slide in inside an already-open notch.
        .animation(isExpanded ? nil : Theme.Motion.respecting(reduceMotion, Theme.Motion.retract), value: isExpanded)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showUndelivered)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showLearned)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showCleanupReady)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showBanner)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showReminder)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showCommandConfirmation)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showDaySummary)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: state.shouldShowDeliveredBeat)
    }

    @ViewBuilder
    private var band: some View {
        if showCommandConfirmation, let message = state.commandConfirmation {
            NotchCommandConfirmationBanner(message: message)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenNotes)
        } else if showDaySummary, let summary = state.activeDaySummary {
            NotchDaySummaryBanner(summary: summary)
        } else if showUndelivered {
            NotchUndeliveredBanner()
        } else if showLearned, let term = state.learnedTerm {
            NotchLearnedBanner(term: term)
        } else if showCleanupReady {
            NotchCleanupReadyBanner()
        } else if showBanner {
            NotchBluetoothBanner(state: state)
        } else if showReminder, let line = state.activeReminder {
            NotchReminderBanner(text: line)
        } else {
            DictationStatusView(state: state)
        }
    }
}
