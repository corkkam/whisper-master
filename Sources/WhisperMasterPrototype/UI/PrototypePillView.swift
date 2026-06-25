import SwiftUI

/// The notch-anchored dictation surface.
///
/// A single black `NotchShape` wraps the physical notch — extending past it on
/// the left and right and hanging below in a thicker band that holds the
/// `DictationStatusView`. When there's something to show it extrudes downward
/// out of the notch; otherwise it retracts back up and disappears.
struct PrototypePillView: View {
    let state: PrototypeAppState
    var geometry: NotchGeometry = .none
    var layout: NotchSurfaceLayout = NotchSurfaceLayout()

    private var expandedHeight: CGFloat {
        geometry.notchHeight + layout.bottomThickness
    }

    /// Whether the surface should be dropped down and visible.
    private var isExpanded: Bool {
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
            Color.clear.frame(height: geometry.notchHeight)

            DictationStatusView(state: state)
                .frame(maxWidth: .infinity)
                .frame(height: layout.bottomThickness)
        }
        .frame(height: isExpanded ? expandedHeight : 0, alignment: .top)
        .background(shape.fill(.black))
        .clipShape(shape)
        .opacity(isExpanded ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: isExpanded)
    }
}
