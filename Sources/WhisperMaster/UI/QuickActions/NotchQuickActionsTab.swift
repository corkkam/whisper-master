import Foundation

/// Which page of the quick-actions band is showing.
///
/// Today and Notes are fixed; every connection the user pinned on the Connectors
/// page adds a `.connector` tab of its own, in pin order; Settings sits behind the
/// gear. There is deliberately no "Connectors" overview tab — pinning *is* the
/// overview, and a page listing the pins would be one more click to the thing.
enum NotchQuickActionsTab: Equatable, Hashable {
    case today
    case notes
    case connector(UUID)
    case settings

    /// `UserDefaults` key for the tab the band reopens on. Device-wide on purpose:
    /// which page you glance at is a habit of the person at the keyboard, and a
    /// stale connector id is resolved away by `resolved(pinned:)` anyway.
    static let defaultsKey = "WhisperMaster.quickActionsTab.v1"

    /// Stable string form for persistence: `today`, `notes`, `settings`, or
    /// `connector:<uuid>`.
    var storageValue: String {
        switch self {
        case .today: return "today"
        case .notes: return "notes"
        case .settings: return "settings"
        case .connector(let id): return "connector:\(id.uuidString)"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "today": self = .today
        case "notes": self = .notes
        case "settings": self = .settings
        default:
            let prefix = "connector:"
            guard storageValue.hasPrefix(prefix),
                  let id = UUID(uuidString: String(storageValue.dropFirst(prefix.count)))
            else { return nil }
            self = .connector(id)
        }
    }

    /// This tab, unless it names a connection that is no longer pinned — then
    /// Today. A tab bar must never select a tab it isn't drawing.
    func resolved(pinned: [UUID]) -> NotchQuickActionsTab {
        if case .connector(let id) = self, !pinned.contains(id) { return .today }
        return self
    }
}
