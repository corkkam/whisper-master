import XCTest

@testable import WhisperMaster

/// The quick-actions band's tabs: which connections are pinned to it, which tab it
/// reopens on, what earns a count, and what a pinned tab is allowed to open.
@MainActor
final class NotchQuickActionsTabsTests: XCTestCase {
    private func makeStore() -> ConnectorInstanceStore {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        return store
    }

    private func gmail(_ label: String) -> ConnectorInstance {
        ConnectorInstance(kind: .gmail, label: label, identity: "\(label)@acme.com", config: .googleOAuth)
    }

    // MARK: - Pins

    func testPinsKeepTheirOrderAndStopAtTheLimit() {
        let store = makeStore()
        let ids = ["A", "B", "C", "D"].map { store.add(gmail($0)).id }

        XCTAssertTrue(store.setPinnedToNotch(ids[2], true))
        XCTAssertTrue(store.setPinnedToNotch(ids[0], true))
        XCTAssertTrue(store.setPinnedToNotch(ids[1], true))
        XCTAssertFalse(store.canPinToNotch)
        XCTAssertFalse(store.setPinnedToNotch(ids[3], true), "a fourth pin is refused")

        // Tab order is pin order, not connection order.
        XCTAssertEqual(store.pinnedToNotch.map(\.id), [ids[2], ids[0], ids[1]])
    }

    func testUnpinningFreesASlot() {
        let store = makeStore()
        let ids = ["A", "B", "C", "D"].map { store.add(gmail($0)).id }
        ids.prefix(3).forEach { store.setPinnedToNotch($0, true) }

        store.setPinnedToNotch(ids[0], false)
        XCTAssertTrue(store.setPinnedToNotch(ids[3], true))
        XCTAssertEqual(store.pinnedToNotch.map(\.id), [ids[1], ids[2], ids[3]])
    }

    func testRemovingAConnectionTakesItsPinWithIt() {
        let store = makeStore()
        let id = store.add(gmail("Work")).id
        store.setPinnedToNotch(id, true)

        store.remove(id)
        XCTAssertTrue(store.pinnedToNotch.isEmpty)
        XCTAssertFalse(store.isPinnedToNotch(id))
    }

    func testAnUnknownConnectionCannotBePinned() {
        let store = makeStore()
        XCTAssertFalse(store.setPinnedToNotch(UUID(), true))
        XCTAssertTrue(store.pinnedToNotch.isEmpty)
    }

    // MARK: - Which tab it reopens on

    func testATabSurvivesTheTripThroughStorage() {
        let id = UUID()
        for tab in [NotchQuickActionsTab.today, .notes, .settings, .connector(id)] {
            XCTAssertEqual(NotchQuickActionsTab(storageValue: tab.storageValue), tab)
        }
        XCTAssertNil(NotchQuickActionsTab(storageValue: "connector:not-a-uuid"))
    }

    func testAConnectorTabWhosePinIsGoneFallsBackToToday() {
        let id = UUID()
        XCTAssertEqual(NotchQuickActionsTab.connector(id).resolved(pinned: [id]), .connector(id))
        XCTAssertEqual(NotchQuickActionsTab.connector(id).resolved(pinned: []), .today)
        XCTAssertEqual(NotchQuickActionsTab.notes.resolved(pinned: []), .notes)
    }

    // MARK: - Counts

    func testMailCountsOnlyWhatIsUnread() {
        let feed = NotchConnectorFeed(store: makeStore())
        let id = UUID()
        feed.seed(id, .items([
            ConnectorItem(id: "1", title: "a", isUnread: true),
            ConnectorItem(id: "2", title: "b", isUnread: true),
            ConnectorItem(id: "3", title: "c"),
        ]))
        XCTAssertEqual(feed.badge(for: id), 2)
    }

    /// Slack's read is recent messages, not unread ones — a count there would be a
    /// number that means nothing, so it gets none.
    func testRecentItemsWithNothingUnreadEarnNoCount() {
        let feed = NotchConnectorFeed(store: makeStore())
        let id = UUID()
        feed.seed(id, .items([ConnectorItem(id: "1", title: "a"), ConnectorItem(id: "2", title: "b")]))
        XCTAssertNil(feed.badge(for: id))
    }

    func testACalendarCountsOnlyWhatIsStillAhead() {
        let feed = NotchConnectorFeed(store: makeStore())
        let id = UUID()
        let now = Date()
        func event(_ id: String, endsIn minutes: Double) -> DayEvent {
            DayEvent(id: id, title: id, start: now.addingTimeInterval(minutes * 60 - 1_800),
                     end: now.addingTimeInterval(minutes * 60), isAllDay: false,
                     calendarTitle: "Work", sourceTitle: "Google")
        }
        feed.seed(id, .events([event("gone", endsIn: -10), event("now", endsIn: 10), event("later", endsIn: 90)]))
        XCTAssertEqual(feed.badge(for: id, now: now), 2)
    }

    // MARK: - What is read

    func testAPausedOrRejectedConnectionIsNotRead() {
        var instance = gmail("Work")
        XCTAssertTrue(NotchConnectorFeed.shouldRead(instance))

        instance.isEnabled = false
        XCTAssertFalse(NotchConnectorFeed.shouldRead(instance), "paused means off")

        instance.isEnabled = true
        instance.lastError = .credentialInvalid
        XCTAssertFalse(NotchConnectorFeed.shouldRead(instance), "a retry can't fix a rejected credential")

        // These clear on their own, so the band keeps trying.
        instance.lastError = .rateLimited
        XCTAssertTrue(NotchConnectorFeed.shouldRead(instance))
        instance.lastError = .unreachable
        XCTAssertTrue(NotchConnectorFeed.shouldRead(instance))
    }

    // MARK: - What a pinned tab may open

    func testOnlyHTTPSAndTheCalendarAppAreOpenable() {
        XCTAssertTrue(NotchConnectorLinks.isOpenable(URL(string: "https://mail.google.com/mail/u/0/#inbox/1")!))
        XCTAssertTrue(NotchConnectorLinks.isOpenable(NotchConnectorLinks.calendarApp))

        XCTAssertFalse(NotchConnectorLinks.isOpenable(URL(string: "http://mail.google.com/")!))
        XCTAssertFalse(NotchConnectorLinks.isOpenable(URL(fileURLWithPath: "/Applications/Terminal.app")))
        XCTAssertFalse(NotchConnectorLinks.isOpenable(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(NotchConnectorLinks.isOpenable(URL(string: "slack://open")!))
    }

    func testEveryKindHasAnOpenableHome() {
        for kind in ConnectorKind.allCases {
            let instance = ConnectorInstance(kind: kind, label: kind.displayName, identity: "x", config: .empty)
            guard let home = NotchConnectorLinks.home(for: instance) else {
                return XCTFail("\(kind) has no home")
            }
            XCTAssertTrue(NotchConnectorLinks.isOpenable(home), "\(kind) → \(home)")
        }
    }

    /// A calendar this Mac syncs opens in Calendar, whatever account it came from.
    func testASyncedCalendarOpensTheCalendarApp() {
        let synced = ConnectorInstance(kind: .googleCalendar, label: "Work", identity: "x",
                                       config: .calendars(identifiers: [], sourceTitle: "Google"))
        XCTAssertEqual(NotchConnectorLinks.home(for: synced), NotchConnectorLinks.calendarApp)
        XCTAssertEqual(NotchConnectorLinks.appName(for: synced), "Calendar")
    }

    // MARK: - Depth

    /// Only Today has column captions; every other page lists rows straight under
    /// the tab bar, so the same row count makes a shallower band.
    func testPagesWithoutCaptionsAreShallower() {
        let layout = NotchQuickActionsLayout()
        XCTAssertLessThan(layout.thickness(rows: 3, captioned: false), layout.thickness(rows: 3))
    }
}
