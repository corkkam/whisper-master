import SwiftUI

/// Step 5 — the live mic check. The waveform reacts to real input here; this is
/// the motif's loud moment. Capture start/stop is owned by the flow and injected.
struct MicTestPage: View {
    let micGranted: Bool
    let level: Float
    let running: Bool
    let heardSound: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                KickerLabel("Sound check")
                Text(micGranted ? "Say something" : "Mic check skipped")
                    .font(Typography.sans(23, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(prompt)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ZStack {
                OnboardingWaveform(level: level, active: running, ambient: !micGranted)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 24)
            }
            .frame(height: 130)
            .onboardingCard(highlighted: heardSound)

            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(heardSound ? Theme.success : Theme.textSecondary)
                Text(statusText)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if micGranted, !running, !heardSound {
                    SecondaryButton(title: "Start mic check") { onStart() }
                }
            }

            Spacer(minLength: 0)
        }
        .onAppear(perform: onStart)
        .onDisappear(perform: onStop)
    }

    private var prompt: String {
        if !micGranted {
            return "No mic access yet, so there's nothing to test. You can turn it on anytime in Settings — for now, just continue."
        }
        return heardSound
            ? "Heard you loud and clear. Looking good."
            : "Speak a sentence — try \"Hello Whisper, can you hear me?\". The bars should move."
    }

    private var statusIcon: String {
        if heardSound { return "checkmark.circle.fill" }
        return running ? "ear" : "ear.badge.waveform"
    }

    private var statusText: String {
        if !micGranted { return "Microphone is off." }
        if heardSound { return "Audio reaching the app." }
        if running { return "Listening…" }
        return "Press start to test your microphone."
    }
}
