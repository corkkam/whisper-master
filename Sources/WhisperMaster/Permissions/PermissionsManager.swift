import AppKit
import AVFoundation
import ApplicationServices
import UserNotifications

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

    /// Mirror of `MicStatus` for notification authorization. Provisional and
    /// ephemeral authorizations still deliver our update banner, so they count
    /// as granted.
    enum NotifStatus {
        case notDetermined
        case denied
        case granted

        init(_ status: UNAuthorizationStatus) {
            switch status {
            case .notDetermined:
                self = .notDetermined
            case .authorized, .provisional, .ephemeral:
                self = .granted
            case .denied:
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

    /// Async because notification settings have no synchronous getter (unlike
    /// `AVCaptureDevice.authorizationStatus`).
    func notificationStatus() async -> NotifStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotifStatus(settings.authorizationStatus)
    }

    func requestNotifications() async -> Bool {
        let granted = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        return granted ?? false
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

    func openNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.notifications"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
