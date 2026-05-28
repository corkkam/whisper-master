import SwiftUI

struct InfinityWaveView: View {
    let level: Float

    var barCount: Int = 9
    var maxBarHeight: CGFloat = 24

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let speech = min(1, max(0, CGFloat(level) * 18))
            let baseline: CGFloat = 0.25
            let amplitude = max(baseline, baseline + speech * 0.85)

            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    let phase = t * 5.5 + Double(index) * 0.55
                    let wobble = sin(phase) * 0.5 + 0.5
                    let height = max(4, amplitude * maxBarHeight * CGFloat(wobble))

                    Capsule()
                        .fill(gradient)
                        .frame(width: 3, height: height)
                }
            }
        }
    }

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.55, green: 0.85, blue: 1.0),
                .white
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
