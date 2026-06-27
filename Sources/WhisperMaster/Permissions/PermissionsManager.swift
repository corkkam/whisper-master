import AppKit
import AVFoundation
import ApplicationServices

@MainActor
final class PermissionsManager {
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
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
