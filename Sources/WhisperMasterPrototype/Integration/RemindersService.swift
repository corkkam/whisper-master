import EventKit
import Foundation

actor RemindersService {
    private let store = EKEventStore()

    /// Call early (e.g. at launch) to surface the system permission dialog before the user
    /// first tries to create a reminder.
    func requestAccessIfNeeded() async {
        _ = try? await requestAccess()
    }

    func createReminder(title: String) async throws {
        let granted = try await requestAccess()
        guard granted else {
            throw RemindersServiceError.accessDenied
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()
        try store.save(reminder, commit: true)
    }

    private func requestAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            return try await store.requestFullAccessToReminders()
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .reminder) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    enum RemindersServiceError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            "Reminders access denied. Enable it in System Settings > Privacy & Security > Reminders."
        }
    }
}
