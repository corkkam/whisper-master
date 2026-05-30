import AppKit
import AVFoundation
import ApplicationServices
import EventKit

@MainActor
final class PermissionsManager {

    // MARK: - Microphone

    enum MicStatus {
        case notDetermined
        case denied
        case granted

        init(_ status: AVAuthorizationStatus) {
            switch status {
            case .notDetermined:
                self = .notDetermined
            case .authorized:
                self = .granted
            case .denied, .restricted:
                self = .denied
            @unknown default:
                self = .denied
            }
        }
    }

    func microphoneStatus() -> MicStatus {
        MicStatus(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Accessibility

    func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    func promptAccessibility() {
        let options: [String: Any] = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Reminders

    enum RemindersStatus {
        case notDetermined
        case denied
        case granted
    }

    func remindersStatus() -> RemindersStatus {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .writeOnly:
            return .granted
        case .fullAccess:
            return .granted
        @unknown default:
            return .notDetermined
        }
    }

    func openRemindersSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
