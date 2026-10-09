import SwiftUI

/// Maps the current app state to the indicator shown inside the notch surface.
///
/// A single `ThreadView` covers every "working" state so it morphs in place:
/// it's the open wave while recording and folds into a spinning ring while
/// preparing, loading an engine, or finalizing. Download keeps its own
/// determinate progress, and failures show an error glyph.
struct DictationStatusView: View {
    let state: AppState

    var body: some View {
        if let download = state.download {
            downloadProgress(download.fractionCompleted)
        } else if isFailed {
            errorGlyph
        } else if isRecording {
            recordingIndicator
        } else if isWorking {
            ThreadView(level: state.audioLevel, folded: true)
        } else {
            EmptyView()
        }
    }

    /// The live recording band: warm wave + a running elapsed timer, on the dark
    /// notch band (`Theme.Notch`).
    private var recordingIndicator: some View {
        HStack(spacing: 10) {
            ThreadView(level: state.audioLevel, folded: false)
            ElapsedTimerText()
                .font(Typography.monoSmall)
                .foregroundStyle(Theme.Notch.textSecondary)
        }
    }

    // MARK: - State classification

    private var isRecording: Bool {
        if case .recording = state.phase { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = state.phase { return true }
        return false
    }

    /// Any state that should show the thread — recording or an indeterminate
    /// "busy" phase (preparing models, loading an engine, finalizing).
    private var isWorking: Bool {
        if state.preparingEngine != nil { return true }
        switch state.phase {
        case .recording, .preparingModels, .stopping:
            return true
        case .idle, .failed:
            return false
        }
    }

    // MARK: - Subviews

    private var errorGlyph: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.system(size: 12, weight: .bold))
    }

    private func downloadProgress(_ fraction: Double) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .tint(Theme.Notch.accent)
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)
            Text("\(Int(fraction * 100))%")
                .foregroundStyle(Theme.Notch.textPrimary)
                .font(.system(size: 11, weight: .semibold))
        }
    }
}

/// A self-contained mm:ss timer that counts up while shown (used on the notch
/// recording band). Starts at 0 on appear; the band only appears while recording.
private struct ElapsedTimerText: View {
    @State private var seconds = 0

    var body: some View {
        Text(format(seconds))
            .monospacedDigit()
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                seconds += 1
            }
    }

    private func format(_ total: Int) -> String {
        String(format: "%d:%02d", total / 60, total % 60)
    }
}
