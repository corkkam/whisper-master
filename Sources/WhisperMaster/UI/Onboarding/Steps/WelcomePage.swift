import SwiftUI

/// Step 1 — the brand hero, the privacy thesis, and an ambient waveform that
/// introduces the motif carried through the rest of the flow.
struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                BrandLogo(size: 78, cornerRadius: 18)
                VStack(alignment: .leading, spacing: 6) {
                    KickerLabel("Welcome")
                    Text("Whisper Master")
                        .font(Typography.sans(30, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Local-first dictation for macOS")
                        .font(Typography.sans(15))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }

            OnboardingWaveform(ambient: true)
                .frame(height: 34)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 12) {
                OnboardingBullet(text: "Speak, and your words land at the cursor — anywhere on your Mac.")
                OnboardingBullet(text: "Every word is transcribed on-device. Nothing leaves this machine.")
                OnboardingBullet(text: "One permissions screen and a five-second mic check — that's it.")
            }

            Spacer(minLength: 0)
        }
    }
}
