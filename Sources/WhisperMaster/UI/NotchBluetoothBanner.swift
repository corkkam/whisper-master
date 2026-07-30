import SwiftUI

/// The hint shown in the notch when a Bluetooth headset is the mic input: it
/// warns that recording will drop the headset to "call mode" and offers a
/// one-tap switch to the built-in mic. On the dark notch surface via
/// `NotchBannerRow`, with the switch + close as trailing controls.
///
/// Actions operate directly on `AppState` and run the device switch off the
/// main thread — it's a single Core Audio set (the same thing Sound settings
/// does), never coupled to the recording engine, so it can't hang.
struct NotchBluetoothBanner: View {
    let state: AppState

    var body: some View {
        NotchBannerRow(
            icon: "mic.slash.fill",
            title: "Bluetooth mic lowers quality",
            subtitle: "Switch to the built-in mic"
        ) {
            Spacer(minLength: Theme.Space.sm)

            Button(action: useBuiltInMic) {
                Text("Use built-in")
                    .font(Typography.notchTitle)
                    .foregroundStyle(Theme.Notch.surface)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.Notch.text))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            // Icon-only visually, but keeps a text label for VoiceOver.
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Notch.textTertiary)
                .buttonStyle(.plain)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .pointerCursor()
        }
    }

    private func useBuiltInMic() {
        // Hide immediately; the monitor will confirm the input is no longer
        // Bluetooth on its next poll. Run the switch off-main (one Core Audio
        // set — safe in isolation, never near the recording engine).
        state.bluetoothBannerDismissed = true
        Task.detached { _ = AudioInputDevices.switchToBuiltInMic() }
    }

    private func dismiss() {
        state.bluetoothBannerDismissed = true
    }
}
