import Foundation

/// Watches whether the system default audio input is a Bluetooth device and
/// publishes it to `AppState`, so the notch can offer a one-tap switch to the
/// built-in mic (a Bluetooth mic forces the headset into low-quality "call
/// mode"). Detection is read-only and runs off the main thread, so it can never
/// wedge the UI — unlike automatic device switching, which we deliberately
/// don't do.
@MainActor
final class BluetoothInputMonitor {
    private let state: AppState
    private var timer: Timer?
    private let pollInterval: TimeInterval = 2

    init(state: AppState) {
        self.state = state
    }

    func start() {
        guard timer == nil else { return }
        check()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Read the (potentially slow) device state off-main, then apply on main.
    private func check() {
        Task.detached { [weak self] in
            let isBluetooth = AudioInputDevices.isDefaultInputBluetooth()
            await self?.apply(isBluetooth: isBluetooth)
        }
    }

    private func apply(isBluetooth: Bool) {
        guard state.bluetoothInputActive != isBluetooth else { return }
        state.bluetoothInputActive = isBluetooth
        // When the Bluetooth input goes away, clear any prior dismissal so the
        // hint can re-appear next time one becomes the input.
        if !isBluetooth { state.bluetoothBannerDismissed = false }
    }

    deinit { timer?.invalidate() }
}
