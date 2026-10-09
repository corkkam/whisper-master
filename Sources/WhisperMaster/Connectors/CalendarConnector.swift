import AppKit
import EventKit
import Observation
import SwiftUI

/// A single calendar event, flattened from EventKit into a value type the UI can
/// hold without importing EventKit everywhere.
struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    /// The owning calendar's color, for the agenda's leading rule.
    let colorComponents: [CGFloat]

    var tint: Color {
        guard colorComponents.count >= 3 else { return Theme.accent }
        return Color(.sRGB,
                     red: Double(colorComponents[0]),
                     green: Double(colorComponents[1]),
                     blue: Double(colorComponents[2]),
                     opacity: 1)
    }

    /// "9:30 AM" for timed events; "All day" otherwise.
    var timeLabel: String {
        if isAllDay { return "All day" }
        return Self.timeFormatter.string(from: start)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}

/// Read-only EventKit bridge for the Today agenda. Owns one `EKEventStore`,
/// tracks authorization, and maps today's events into `CalendarEvent` values.
/// `@MainActor`/`@Observable` so the UI reacts to access changes.
@MainActor
@Observable
final class CalendarConnector {
    private let store = EKEventStore()
    /// Mirrors `EKEventStore.authorizationStatus`; refreshed on demand.
    private(set) var authorizationStatus: EKAuthorizationStatus

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    /// Full read access has been granted (macOS 14 reports `.fullAccess`; older
    /// deprecated `.authorized` is treated the same).
    var hasAccess: Bool {
        switch authorizationStatus {
        case .fullAccess:
            return true
        case .authorized:
            return true
        default:
            return false
        }
    }

    /// True while the user hasn't been asked yet — so the UI shows "Connect"
    /// rather than "Denied".
    var isUndetermined: Bool { authorizationStatus == .notDetermined }

    func refreshAuthorization() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    /// Prompt for (or re-check) calendar access. Returns whether access is
    /// granted afterward. Safe to call repeatedly.
    @discardableResult
    func requestAccess() async -> Bool {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // Denied / restricted — fall through and report the refreshed status.
        }
        refreshAuthorization()
        return hasAccess
    }

    /// Today's events (midnight → next midnight), sorted by start. Empty when
    /// access isn't granted.
    func todaysEvents(now: Date = Date()) -> [CalendarEvent] {
        guard hasAccess else { return [] }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(86_400)
        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        return store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .map { event in
                CalendarEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "(No title)",
                    start: event.startDate ?? startOfDay,
                    end: event.endDate ?? startOfDay,
                    isAllDay: event.isAllDay,
                    location: event.location?.isEmpty == false ? event.location : nil,
                    colorComponents: Self.components(of: event.calendar?.cgColor)
                )
            }
    }

    private static func components(of cgColor: CGColor?) -> [CGFloat] {
        guard let cgColor,
              let converted = cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let comps = converted.components, comps.count >= 3
        else { return [] }
        return Array(comps.prefix(3))
    }
}
