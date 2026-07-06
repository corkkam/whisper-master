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

    /// The "nowhere to paste" hint is the highest-priority band — it's the
    /// immediate consequence of the dictation the user just finished.
    private var showUndelivered: Bool { state.shouldShowUndeliveredBanner }

    /// The "learned a word" confirmation — just under the undelivered hint.
    private var showLearned: Bool { !showUndelivered && state.shouldShowLearnedBanner }

    /// The one-shot "smart cleanup is ready" confirmation — just under the
    /// learned hint. (Model download *progress* never appears here.)
    private var showCleanupReady: Bool { !showUndelivered && !showLearned && state.shouldShowCleanupReadyBanner }

    /// The Bluetooth-mic hint takes precedence over the dictation indicator and
    /// uses a taller band to fit its text + button.
    private var showBanner: Bool { !showUndelivered && !showLearned && !showCleanupReady && state.shouldShowBluetoothBanner }

    /// A gentle reminder — lower priority than the hints above, shown only when
    /// idle (`AppState.shouldShowReminder` already gates that).
    private var showReminder: Bool { !showUndelivered && !showLearned && !showCleanupReady && !showBanner && state.shouldShowReminder }

    private var bandThickness: CGFloat {
        if showUndelivered { return layout.undeliveredThickness }
        if showLearned { return layout.learnedThickness }
        if showCleanupReady { return layout.cleanupReadyThickness }
        if showBanner { return layout.bannerThickness }
        if showReminder { return layout.reminderThickness }
        return layout.bottomThickness
    }

    private var expandedHeight: CGFloat {
        geometry.notchHeight + bandThickness
    }

    /// Whether the surface should be dropped down and visible.
    private var isExpanded: Bool {
        if showUndelivered || showLearned || showCleanupReady || showBanner || showReminder { return true } // hints show even when idle
        guard hasContent else { return false }
        if state.phase == .idle && state.hidePillWhenIdle { return false }
        return true
    }

    /// Whether any state is worth surfacing at all.
    private var hasContent: Bool {
        if state.download != nil || state.preparingEngine != nil { return true }
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
        .background(shape.fill(.black))
        .clipShape(shape)
        .opacity(isExpanded ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Only the interactive banner takes clicks; the dictation indicator stays
        // click-through (the panel toggles ignoresMouseEvents to match).
        .allowsHitTesting(showBanner)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: isExpanded)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: showUndelivered)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: showLearned)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: showCleanupReady)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: showBanner)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: showReminder)
    }

    @ViewBuilder
    private var band: some View {
        if showUndelivered {
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
