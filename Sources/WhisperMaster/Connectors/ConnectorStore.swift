import Foundation
import Observation

/// The user's connector choices: which connectors they've turned on, plus the
/// live macOS Calendar authorization status that the calendar connectors depend
/// on. `@Observable` so the Settings tab reacts; owned by `AppState`.
///
/// Connectors are inherently tied to the *person*, not the device, but since they
/// reach external accounts (and calendar access is a system TCC grant that's
/// already per-user on the Mac) this store persists device-wide in `UserDefaults`
/// rather than per-Clerk-account — simpler, and matches how `hotkey`/vocabulary
/// are stored. If multi-account connector scoping is ever needed, mirror the
/// `usageStore.activate(userID:)` pattern.
@MainActor
@Observable
final class ConnectorStore {
    static let enabledDefaultsKey = "WhisperMaster.connectors.enabled.v1"

    /// The connectors the user has switched on.
    private(set) var enabled: Set<ConnectorKind>

    /// Live EventKit authorization for calendars, refreshed by `CalendarConnector`.
    /// Drives the "Allow calendar access" affordance on the calendar connectors.
    var calendarAccessGranted: Bool = false

    /// When false, mutations don't touch `UserDefaults` — used by the headless
    /// snapshot renderer so seeding mock connectors never pollutes real choices.
    var persistenceEnabled: Bool = true

    init(load: Bool = true) {
        enabled = load ? Self.loadEnabled() : []
    }

    func isEnabled(_ kind: ConnectorKind) -> Bool { enabled.contains(kind) }

    /// Turn a connector on/off. Persists immediately (unless persistence is off).
    func setEnabled(_ kind: ConnectorKind, _ on: Bool) {
        if on { enabled.insert(kind) } else { enabled.remove(kind) }
        if persistenceEnabled { Self.persist(enabled) }
    }

    /// Whether any calendar-bearing connector is on (so a day summary should read
    /// events from EventKit).
    var anyCalendarEnabled: Bool {
        enabled.contains { $0.feedsCalendar }
    }

    /// Enabled connectors in a stable display order (featured first).
    var enabledOrdered: [ConnectorKind] {
        ConnectorKind.allCases.filter { enabled.contains($0) }
    }

    private static func loadEnabled() -> Set<ConnectorKind> {
        let raw = UserDefaults.standard.stringArray(forKey: enabledDefaultsKey) ?? []
        return Set(raw.compactMap(ConnectorKind.init(rawValue:)))
    }

    private static func persist(_ set: Set<ConnectorKind>) {
        UserDefaults.standard.set(set.map(\.rawValue), forKey: enabledDefaultsKey)
    }
}
