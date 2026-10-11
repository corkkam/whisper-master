import Foundation

/// Where a pinned connector's tab can send you, and the short words it uses.
///
/// **What the band may open is an allowlist, checked twice** — here, when a row
/// decides whether it is clickable, and again at `AppDelegate.openNotchLink` before
/// `NSWorkspace.open`, which will launch anything it is handed. An item's link comes
/// from a third party's API response, so only `https` and the system Calendar app
/// pass; a `file:` or custom-scheme URL from a mail header never reaches the system.
enum NotchConnectorLinks {
    /// The system Calendar app — where an EventKit-backed calendar lives.
    static let calendarApp = URL(fileURLWithPath: "/System/Applications/Calendar.app")

    static func isOpenable(_ url: URL) -> Bool {
        if url.standardizedFileURL == calendarApp.standardizedFileURL { return true }
        return url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }

    /// The connector's own home: the web app for an account, Calendar for a calendar
    /// this Mac already syncs.
    static func home(for instance: ConnectorInstance) -> URL? {
        if instance.config.calendarIdentifiers != nil { return calendarApp }
        let string: String
        switch instance.kind {
        case .gmail: string = "https://mail.google.com/"
        case .googleCalendar: string = "https://calendar.google.com/"
        case .appleCalendar, .outlook: return calendarApp
        case .slack:
            if case .workspace(let teamID) = instance.config, !teamID.isEmpty,
               teamID.allSatisfy({ $0.isLetter || $0.isNumber }) {
                string = "https://app.slack.com/client/\(teamID)"
            } else {
                string = "https://app.slack.com/"
            }
        case .notion: string = "https://www.notion.so/"
        case .linear: string = "https://linear.app/"
        case .googleDrive: string = "https://drive.google.com/"
        case .github: string = "https://github.com/"
        case .zoom: string = "https://zoom.us/"
        case .asana: string = "https://app.asana.com/"
        }
        return URL(string: string)
    }

    /// The word on the "Open …" button — the app the user knows, not their label
    /// for the connection ("Open Gmail", never "Open Work").
    static func appName(for instance: ConnectorInstance) -> String {
        if home(for: instance) == calendarApp { return "Calendar" }
        return instance.kind.displayName
    }

    /// How old something is, in the fewest words: the clock time today,
    /// "Yesterday", a weekday inside the week, a date beyond it.
    static func age(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return NowPhrase.clock.string(from: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        if days >= 0 && days < 7 { return weekday.string(from: date) }
        return day.string(from: date)
    }

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()
}
