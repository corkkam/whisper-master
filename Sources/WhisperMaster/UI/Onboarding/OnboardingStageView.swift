import SwiftUI

/// The first-launch opening: one black `NotchShape` grows out of the notch, the
/// orb gathers into a sphere of dots, the app's name and one line hold long
/// enough to read, then the shape folds into the band's exact frame. Nothing on
/// it asks for anything; a click on the black skips it.
///
/// Every frame is `OpeningTimeline` at the model's clock, so the snapshot
/// renderer draws any instant. Hidden from VoiceOver: under VoiceOver there is no
/// stage at all.
struct OnboardingStageView: View {
    let model: NotchOnboardingModel
    var geometry: NotchGeometry = .none
    var layout = NotchOnboardingLayout()
    /// The orb's instant, for a snapshot (`0.6 + elapsed`). Nil runs the wall clock.
    var orbTime: Double? = nil

    var body: some View {
        // The stage lives under four seconds and moves the whole time.
        TimelineView(.animation(minimumInterval: nil, paused: model.clock.isFixed)) { _ in
            stage(frame(at: model.clock.now()))
        }
        .accessibilityHidden(true)
    }

    private func frame(at now: TimeInterval) -> OpeningTimeline.Frame {
        let g = OpeningTimeline.Geometry(geometry, layout: layout)
        guard let start = model.openingStartedAt else { return OpeningTimeline.swapFrame(g, layout: layout) }
        if let skip = model.openingSkip {
            let from = OpeningTimeline.frame(at: skip.elapsed, g, layout: layout, policy: model.policy)
            return OpeningTimeline.skipFrame(at: now - skip.at, from: from, g, layout: layout)
        }
        return OpeningTimeline.frame(at: now - start, g, layout: layout, policy: model.policy)
    }

    private func stage(_ f: OpeningTimeline.Frame) -> some View {
        let shape = NotchShape(topConcaveRadius: layout.topConcaveRadius, bottomCornerRadius: f.bottomRadius)
        let height = geometry.notchHeight + f.depth
        let panel = layout.stagePanelSize(for: geometry)

        return ZStack {
            Theme.Notch.surface
            OrbView(
                level: 0,
                mode: OrbFigure.stage,
                diameter: f.orbDiameter,
                preset: .large,
                entrance: false,
                time: orbTime,
                staticFrame: model.policy.orbIsStatic,
                gain: 0,
                gather: f.orbGather
            )
            .position(x: f.width / 2, y: geometry.notchHeight + f.orbCenterY)
            Text(OnboardingCopy.wordmark)
                .font(Typography.stageWordmark)
                .tracking(Typography.stageWordmarkTracking)
                .foregroundStyle(Theme.Notch.text)
                .fixedSize()
                .opacity(f.wordmark.opacity)
                .position(x: f.width / 2, y: geometry.notchHeight + layout.stageWordmarkY + f.wordmark.y)
            Text(OnboardingCopy.tagline)
                .font(Typography.stageTagline)
                .foregroundStyle(Theme.Notch.textSecondary)
                .fixedSize()
                .opacity(f.tagline.opacity)
                .position(x: f.width / 2, y: geometry.notchHeight + layout.stageTaglineY + f.tagline.y)
        }
        .frame(width: f.width, height: height)
        .clipShape(shape)
        .allowsHitTesting(false)
        .overlay(alignment: .bottom) {
            // A click on the black below the notch strip skips. The shape also
            // covers the menu-bar strip, up to the stage's width: its opaque
            // pixels take a click there, which neither skips nor reaches the
            // menu bar.
            Color.clear
                .frame(height: f.depth)
                .contentShape(Rectangle())
                .onTapGesture { model.skipOpening() }
        }
        .opacity(f.opacity)
        .onDarkSurface()
        .frame(width: panel.width, height: panel.height, alignment: .top)
    }
}
