import SwiftUI

/// Maps the current app state to the indicator shown inside the notch surface.
///
/// Priority: an in-flight model **download** shows determinate progress; a
/// **failure** shows an error glyph plus a short reason; a finished **polish**
/// shows the rewritten transcript for a beat; any **working** state shows the
/// live dictation line (the orb — listening while recording, thinking while the
/// on-device polish runs — alongside the words as they land); a just-landed
/// transcript shows the **delivered** checkmark; otherwise nothing.
struct DictationStatusView: View {
    let state: AppState
    /// The transcript already wrapped for the current band width. Resolved by the
    /// owner so the band's height and this view's line count can't disagree.
    var transcript: NotchTranscriptModel = NotchTranscriptModel()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let download = state.download {
                downloadProgress(download.fractionCompleted)
            } else if isFailed {
                failure
            } else if state.shouldShowPolishedBeat, let polished = state.polishedText {
                polishedBeat(polished)
            } else if isWorking {
                liveTranscript
            } else if state.shouldShowDeliveredBeat {
                delivered
            } else {
                EmptyView()
            }
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

    /// Any state that should show the orb — recording, an indeterminate "busy"
    /// phase (preparing models, loading an engine, finalizing), or the polish
    /// that runs on after the transcript has already been delivered.
    private var isWorking: Bool {
        if state.preparingEngine != nil { return true }
        if state.isPolishing { return true }
        switch state.phase {
        case .recording, .preparingModels, .stopping:
            return true
        case .idle, .failed:
            return false
        }
    }

    /// Which figure the orb draws for the current work.
    private var orbMode: OrbView.Mode {
        if isRecording { return .listening }
        if state.isPolishing { return .thinking }
        return .working
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

    /// How the live line is announced: the state, then the words.
    private var liveStateWord: String {
        if isRecording { return "Listening" }
        if state.isPolishing { return "Polishing" }
        if state.preparingEngine != nil { return "Getting ready" }
        return "Transcribing"
    }

    /// What the live line is spoken as: the transcript once there are words,
    /// otherwise the state on its own.
    private var liveAccessibilityLabel: String {
        let words = state.liveTranscriptText
        return words.isEmpty ? liveStateWord : "\(liveStateWord). \(words)"
    }

    // MARK: - Subviews

    /// The orb plus the words as they land — the whole recording → finalizing →
    /// polishing stretch. Confirmed text is full strength, the volatile tail
    /// quieter; once the transcript is final it is all confirmed.
    private var liveTranscript: some View {
        NotchTranscriptRow(
            model: transcript,
            level: state.audioLevel,
            mode: orbMode,
            accessibilityLabel: liveAccessibilityLabel
        )
    }

    /// The rewritten transcript, held for a beat so the polish is visible rather
    /// than a silent substitution.
    private func polishedBeat(_ text: String) -> some View {
        NotchTranscriptRow(
            model: transcript,
            icon: "sparkles",
            accessibilityLabel: "Polished. \(text)"
        )
    }

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(failureReason)
    }

    /// The success beat: a checkmark that bounces in (unless Reduce Motion is on)
    /// and scales/fades with the surface.
    @ViewBuilder
    private var delivered: some View {
        Group {
            if reduceMotion {
                deliveredGlyph
            } else {
                deliveredGlyph
                    .symbolEffect(.bounce, value: state.shouldShowDeliveredBeat)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Delivered")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloading \(Int(fraction * 100)) percent")
    }
}
