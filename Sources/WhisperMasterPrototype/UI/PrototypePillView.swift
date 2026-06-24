import SwiftUI

struct PrototypePillView: View {
    let state: PrototypeAppState

    private var pillWidth: CGFloat { 168 }
    private var pillHeight: CGFloat { 34 }

    private var isHidden: Bool {
        state.phase == .idle
            && state.download == nil
            && state.preparingEngine == nil
            && state.hidePillWhenIdle
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.black.opacity(0.85))
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

            content
                .padding(.horizontal, 14)
        }
        .frame(width: pillWidth, height: pillHeight)
        .opacity(isHidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.22), value: isHidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    private var content: some View {
        if let download = state.download {
            HStack(spacing: 8) {
                ProgressView(value: download.fractionCompleted)
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.55)
                    .frame(width: 14, height: 14)
                Text("\(Int(download.fractionCompleted * 100))%")
                    .foregroundStyle(.white)
                    .font(.system(size: 11, weight: .semibold))
            }
        } else if state.preparingEngine != nil {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                Text("Loading engine")
                    .foregroundStyle(.white)
                    .font(.system(size: 10, weight: .semibold))
            }
        } else {
            switch state.phase {
            case .idle:
                EmptyView()
            case .preparingModels, .stopping:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                    Text(state.phase == .stopping ? "Finalizing" : "Preparing")
                        .foregroundStyle(.white)
                        .font(.system(size: 10, weight: .medium))
                }
            case .recording:
                InfinityWaveView(level: state.audioLevel)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 12, weight: .bold))
            }
        }
    }
}
