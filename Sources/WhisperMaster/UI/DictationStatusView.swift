import SwiftUI

/// Maps the current app state to the indicator shown inside the notch surface.
///
/// Priority: an in-flight model **download** shows determinate progress; a
/// **failure** shows an error glyph plus a short reason; a just-landed
/// transcript shows the **delivered** checkmark beat; any other **working**
/// state shows the `OrbView` (energized/audio-reactive while recording, calmly
/// breathing while preparing/loading/finalizing); otherwise nothing.
struct DictationStatusView: View {
    let state: AppState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let download = state.download {
                downloadProgress(download.fractionCompleted)
            } else if isFailed {
                failure
            } else if state.shouldShowDeliveredBeat {
                delivered
            } else if isWorking {
                OrbView(level: state.audioLevel, energized: isRecording)
            } else {
                EmptyView()
            }
        }
        // Collapse to a single spoken element describing the current state.
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
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

    /// A short, human failure line — the status message with its diagnostic
    /// prefix stripped, or a friendly fallback when there's nothing to show.
    private var failureReason: String {
        let prefix = "Transcription failed: "
        var message = state.statusMessage
        if message.hasPrefix(prefix) { message = String(message.dropFirst(prefix.count)) }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Dictation failed — try again" : message
    }

    private var accessibilityLabel: String {
        if let download = state.download {
            return "Downloading \(Int(download.fractionCompleted * 100)) percent"
        }
        if isFailed { return failureReason }
        if state.shouldShowDeliveredBeat { return "Delivered" }
        if isWorking { return isRecording ? "Listening" : "Transcribing" }
        return ""
    }

    // MARK: - Subviews

    private var failure: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.Notch.danger)
            Text(failureReason)
                .font(Typography.notchBody)
                .foregroundStyle(Theme.Notch.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, Theme.Space.md)
    }

    /// The success beat: a checkmark that bounces in (unless Reduce Motion is on)
    /// and scales/fades with the surface.
    @ViewBuilder
    private var delivered: some View {
        if reduceMotion {
            deliveredGlyph
        } else {
            deliveredGlyph
                .symbolEffect(.bounce, value: state.shouldShowDeliveredBeat)
        }
    }

    private var deliveredGlyph: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.Notch.success)
            .transition(.scale.combined(with: .opacity))
    }

    private func downloadProgress(_ fraction: Double) -> some View {
        HStack(spacing: Theme.Space.sm) {
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .tint(Theme.Notch.text)
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)
            Text("\(Int(fraction * 100))%")
                .foregroundStyle(Theme.Notch.text)
                .font(Typography.notchBody)
        }
    }
}
