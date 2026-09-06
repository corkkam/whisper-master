import SwiftUI

/// Maps the current app state to the indicator shown inside the notch surface.
///
/// Priority: an in-flight model **download** shows determinate progress; a
/// **failure** shows an error glyph plus a short reason; a finished **polish**
/// shows the rewritten transcript for a beat; any **working** state shows the
/// dictation line (the state in words plus the orb — listening while recording,
/// thinking while the on-device polish runs, and *never* the transcript as it
/// streams); a just-landed transcript shows the **delivered** checkmark;
/// otherwise nothing.
struct DictationStatusView: View {
    let state: AppState
    /// The transcript already wrapped for the current band width. Resolved by the
    /// owner so the band's height and this view's line count can't disagree.
    var transcript: NotchTranscriptModel = NotchTranscriptModel()
    /// What the band is doing, resolved by the owner so the light in the surface
    /// and the content inside it can't disagree about the state.
    var activity: NotchActivity = .idle
    /// Metrics for the notch row, when the status is being drawn *in* the menu bar
    /// rather than in a band below it. `nil` keeps the band's own metrics.
    var rowOrbSize: CGFloat?
    var rowVerticalInset: CGFloat?
    /// Ceiling on the leading state word in the row form, where it has to stay
    /// inside the wing beside the camera housing. `nil` in the band form, which
    /// runs below the housing and has the whole surface to use.
    var rowLabelMaxWidth: CGFloat?
    /// The day, for the leading edge. Present only in the row form, and only when
    /// something is actually inside its horizon — see `NotchNowRow`.
    var ambient: NotchAmbientSlot?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch activity {
            case .preparing where state.download != nil:
                downloadProgress(state.download?.fractionCompleted ?? 0)
            case .failed:
                failure
            case .polished:
                polishedBeat(state.polishedText ?? "")
            case .listening, .transcribing, .polishing, .preparing:
                liveTranscript
            case .delivered:
                delivered
            case .idle:
                EmptyView()
            }
        }
    }

    // MARK: - State classification

    /// Which figure the orb draws for the current work. The live branch above only
    /// runs for states that have one, so the fallback is never reached in practice.
    private var orbMode: OrbView.Mode { activity.orbMode ?? .working }

    /// A short, human failure line — the status message with its diagnostic
    /// prefix stripped, or a friendly fallback when there's nothing to show.
    private var failureReason: String {
        let prefix = "Transcription failed: "
        var message = state.statusMessage
        if message.hasPrefix(prefix) { message = String(message.dropFirst(prefix.count)) }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Dictation failed — try again" : message
    }

    /// The state in words — what the bar carries at its leading edge, and what
    /// VoiceOver announces the line as.
    private var liveStateWord: String {
        // Armed *or* still being carried out: the chord's arm is consumed at the stop,
        // but the assistant works on for a beat after it and the band shouldn't
        // suddenly re-caption itself as an ordinary dictation mid-command.
        activity.label(
            holdToTalk: keyIsHoldingItOpen,
            commandCapture: state.commandCaptureArmed || state.commandAgentRunning,
            agentActivity: state.agentActivity)
    }

    /// Whether the *key* is what's keeping the band open. False in toggle mode and
    /// while a double-tap has latched the session hands-free — both cases where
    /// the user has let go and the line needs to say why it's still listening.
    private var keyIsHoldingItOpen: Bool {
        state.holdToTalkEnabled && !state.handsFreeActive
    }

    // MARK: - Subviews

    /// The orb plus the state word — the whole recording → finalizing → polishing
    /// stretch. `transcript` is empty here by design: the band reports what the app
    /// is doing, and the words themselves land in the target app rather than being
    /// read back off the bezel (see `DictationPillContent.transcriptModel`).
    private var liveTranscript: some View {
        NotchTranscriptRow(
            model: transcript,
            level: state.audioLevel,
            mode: orbMode,
            label: liveStateWord,
            accessibilityLabel: liveStateWord,
            orbSize: rowOrbSize,
            verticalInset: rowVerticalInset,
            labelMaxWidth: rowLabelMaxWidth,
            ambient: ambient,
            stateIsLive: activity == .listening
        )
    }

    /// The rewritten transcript, held for a beat so the polish is visible rather
    /// than a silent substitution.
    private func polishedBeat(_ text: String) -> some View {
        NotchTranscriptRow(
            model: transcript,
            icon: "sparkles",
            // Signal: the rewrite is the machine's work, not yours.
            tint: activity.accent ?? Theme.Notch.success,
            label: activity.label(holdToTalk: keyIsHoldingItOpen),
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
