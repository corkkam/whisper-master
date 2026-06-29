import SwiftUI

/// The minimal hint shown in the notch when a Bluetooth headset is the mic
/// input: it warns that recording will drop the headset to "call mode" and
/// offers a one-tap switch to the built-in mic. White-on-black to sit inside
/// the black notch surface.
///
/// Actions operate directly on `AppState` and run the device switch off the
/// main thread — it's a single Core Audio set (the same thing Sound settings
/// does), never coupled to the recording engine, so it can't hang.
struct NotchBluetoothBanner: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            VStack(alignment: .leading, spacing: 1) {
                Text("Bluetooth mic lowers quality")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Switch to the built-in mic")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            Button(action: useBuiltInMic) {
                Text("Use built-in")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
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
