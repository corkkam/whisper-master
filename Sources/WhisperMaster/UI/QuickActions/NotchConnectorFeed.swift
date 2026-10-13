import Foundation
import Observation

/// What each connection pinned to the notch is holding, for its tab in the
/// quick-actions band.
///
/// **Read when the band opens, not on a clock.** A pinned tab is a glance, and the
/// moment someone glances is the one moment the answer has to be fresh; reading
/// three accounts every few minutes for a band that is shut nearly all day would
/// spend the network and the rate limits on answers nobody sees. So the band asks
/// for a refresh as it opens and again when a tab is chosen, and anything read in
/// the last `staleAfter` is served as is. The tab shows what it last had while the
/// read is in flight, so a tab never blanks out to refresh itself.
///
/// It reads through exactly the paths the assistant uses — `recentItems` for mail
/// and messages, `DaySummaryService.buildAsync` for a calendar — and records a
/// failure on the connection the same way they do, so the Connectors page and the
/// band can never disagree about whether an account is working.
@MainActor
@Observable
final class NotchConnectorFeed {
    /// What one pinned connection last returned.
    enum Content: Equatable {
        case items([ConnectorItem])
        case events([DayEvent])
    }

    struct Entry: Equatable {
        var content: Content?
        var loadedAt: Date?
        var isLoading = false
    }

    /// Most rows a connector tab shows. Past this it stops being a glance.
    static let rowLimit = 5
    /// How old a read can be before opening the band reads again.
    static let staleAfter: TimeInterval = 120

    private(set) var entries: [UUID: Entry] = [:]
    private let store: ConnectorInstanceStore

    init(store: ConnectorInstanceStore) {
        self.store = store
    }

    func entry(for id: UUID) -> Entry? { entries[id] }

    /// Read every pinned connection that is due. Safe to call on every open and
    /// every tab change: a read already in flight, a paused connection, and one
    /// whose credential needs the user are all skipped.
    func refresh(_ instances: [ConnectorInstance], now: Date = Date(), force: Bool = false) {
        for instance in instances where Self.shouldRead(instance) {
            let current = entries[instance.id]
            if current?.isLoading == true { continue }
            if !force, let loadedAt = current?.loadedAt, now.timeIntervalSince(loadedAt) < Self.staleAfter {
                continue
            }
            entries[instance.id, default: Entry()].isLoading = true
            Task { [weak self] in
                guard let self else { return }
                let content = await self.read(instance, now: now)
                var entry = self.entries[instance.id] ?? Entry()
                entry.isLoading = false
                if let content {
                    entry.content = content
                    entry.loadedAt = Date()
                }
                self.entries[instance.id] = entry
            }
        }
    }

    /// Put a canned answer in place — the headless snapshot renderer has no network.
    func seed(_ id: UUID, _ content: Content, at date: Date = Date()) {
        entries[id] = Entry(content: content, loadedAt: date)
    }

    /// Forget everything — on sign-out, so the next account never sees this one's
    /// mail for the second before its own read lands.
    func reset() {
        entries = [:]
    }

    /// The tab's count, or nil for none. Only things that are waiting on the user
    /// earn one: unread mail and the events still ahead today. Slack's read is
    /// "recent messages", not unread, so it gets no badge rather than a number that
    /// means nothing.
    func badge(for id: UUID, now: Date = Date()) -> Int? {
        guard let content = entries[id]?.content else { return nil }
        let count: Int
        switch content {
        case .items(let items): count = items.filter(\.isUnread).count
        case .events(let events): count = events.filter { $0.end > now }.count
        }
        return count > 0 ? count : nil
    }

    /// A paused connection is not read (the user turned it off), and one whose
    /// credential was rejected is not read either — a retry can't fix it, and the
    /// tab shows the repair line instead. Rate limits and dropped connections are
    /// retried, since those do clear on their own.
    static func shouldRead(_ instance: ConnectorInstance) -> Bool {
        guard instance.isEnabled else { return false }
        switch instance.lastError {
        case nil, .rateLimited?, .unreachable?: return true
        default: return false
        }
    }

    // MARK: - Reads

    private func read(_ instance: ConnectorInstance, now: Date) async -> Content? {
        if instance.provides(.events) {
            let summary = await DaySummaryService.buildAsync(
                store: store, instances: [instance], scopedTo: nil, now: now)
            // A gap means the read failed; `buildAsync` has already recorded it on
            // the connection, which is where the tab reads its error line from.
            guard summary.gaps.isEmpty else { return nil }
            return .events(summary.events.sorted { $0.start < $1.start })
        }
        guard let provider = ProviderRegistry.itemProvider(for: instance) else { return nil }
        let outcome = await provider.recentItems(for: instance, limit: Self.rowLimit)
        store.setError(instance.id, outcome.error)
        guard outcome.error == nil else { return nil }
        return .items(Array(outcome.value.prefix(Self.rowLimit)))
    }
}
