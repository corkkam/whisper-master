import XCTest

@testable import WhisperMaster

/// The hover recogniser behind the notch quick-actions band. Pure and clock-injected,
/// so the dwell/grace behaviour is pinned here rather than discovered by waving a
/// pointer at a menu bar.
final class NotchHoverGestureTests: XCTestCase {
    private let dwell: TimeInterval = 0.35
    private let grace: TimeInterval = 0.45

    private func gesture() -> NotchHoverGesture {
        NotchHoverGesture(openDwell: 0.35, closeGrace: 0.45)
    }

    // MARK: - Opening

    func testDoesNotOpenBeforeTheDwellElapses() {
        var g = gesture()
        g.update(inside: true, allowed: true, now: 0)
        g.update(inside: true, allowed: true, now: dwell - 0.01)
        XCTAssertFalse(g.isOpen)
    }

    func testOpensOnceThePointerHasRestedForTheDwell() {
        var g = gesture()
        g.update(inside: true, allowed: true, now: 0)
        XCTAssertTrue(g.update(inside: true, allowed: true, now: dwell + 0.05))
        XCTAssertTrue(g.isOpen)
    }

    /// The whole point of the dwell: a pointer crossing the notch on its way to the
    /// menu bar must not summon the panel.
    func testAPointerPassingThroughNeverOpensIt() {
        var g = gesture()
        g.update(inside: true, allowed: true, now: 0)
        g.update(inside: false, allowed: true, now: 0.15)
        g.update(inside: true, allowed: true, now: 0.30)
        // 0.30 s after the *second* arrival — the first visit's clock was discarded.
        g.update(inside: true, allowed: true, now: 0.60)
        XCTAssertFalse(g.isOpen)
        g.update(inside: true, allowed: true, now: 0.30 + dwell + 0.05)
        XCTAssertTrue(g.isOpen)
    }

    func testDoesNotOpenWhileDisallowed() {
        var g = gesture()
        g.update(inside: true, allowed: false, now: 0)
        g.update(inside: true, allowed: false, now: 10)
        XCTAssertFalse(g.isOpen)
    }

    /// Becoming allowed must not hand over a dwell that accumulated while it wasn't.
    func testDwellAccruedWhileDisallowedDoesNotCarryOver() {
        var g = gesture()
        g.update(inside: true, allowed: false, now: 0)
        g.update(inside: true, allowed: true, now: 5)
        XCTAssertFalse(g.isOpen)
        g.update(inside: true, allowed: true, now: 5 + dwell + 0.05)
        XCTAssertTrue(g.isOpen)
    }

    // MARK: - Closing

    private func opened() -> NotchHoverGesture {
        var g = gesture()
        g.update(inside: true, allowed: true, now: 0)
        g.update(inside: true, allowed: true, now: dwell + 0.05)
        XCTAssertTrue(g.isOpen)
        return g
    }

    func testStaysOpenWhileThePointerIsOnIt() {
        var g = opened()
        g.update(inside: true, allowed: true, now: 100)
        XCTAssertTrue(g.isOpen)
    }

    /// The grace is what lets a hand cross the gap from the notch down into the band.
    func testSurvivesABriefTripOffTheEdge() {
        var g = opened()
        g.update(inside: false, allowed: true, now: 1)
        g.update(inside: false, allowed: true, now: 1 + grace - 0.01)
        XCTAssertTrue(g.isOpen)
        g.update(inside: true, allowed: true, now: 1 + grace + 5)
        XCTAssertTrue(g.isOpen, "coming back resets the exit clock")
    }

    func testClosesOnceThePointerHasBeenAwayForTheGrace() {
        var g = opened()
        g.update(inside: false, allowed: true, now: 1)
        XCTAssertTrue(g.update(inside: false, allowed: true, now: 1 + grace + 0.05))
        XCTAssertFalse(g.isOpen)
    }

    /// A dictation starting mid-glance takes the notch back immediately — waiting out
    /// the grace would draw the band over the surface that's reporting live state.
    func testYieldsImmediatelyWhenNoLongerAllowed() {
        var g = opened()
        XCTAssertTrue(g.update(inside: true, allowed: false, now: 1))
        XCTAssertFalse(g.isOpen)
    }

    func testCloseDropsDwellSoItDoesNotReopenOnTheNextTick() {
        var g = opened()
        g.close()
        g.update(inside: true, allowed: true, now: 1)
        XCTAssertFalse(g.isOpen)
        g.update(inside: true, allowed: true, now: 1 + dwell + 0.05)
        XCTAssertTrue(g.isOpen, "a fresh dwell still opens it")
    }
}

/// The shape of the target the pointer has to hit. Pinned here because the failure
/// mode is invisible in code review and tedious to find by hand: a zone that's a few
/// points too tight reads as "the notch only answers at its very edge".
final class NotchQuickActionsZoneTests: XCTestCase {
    private let layout = NotchQuickActionsLayout()
    /// A 14" MacBook Pro: 1512pt wide, ~200pt of camera housing, 37.5pt inset.
    private let geometry = NotchGeometry(notchWidth: 200, notchHeight: 37.5, screenWidth: 1512)
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    private var zone: CGRect { layout.hoverZone(for: geometry, screenFrame: screen) }

    /// The zone reaches the very top of the screen — where the pointer ends up when
    /// it's thrown at the menu bar and stops against it.
    func testTheZoneRunsToTheTopOfTheScreen() {
        XCTAssertEqual(zone.maxY, screen.maxY, accuracy: 0.01)
        XCTAssertTrue(zone.contains(CGPoint(x: screen.midX, y: screen.maxY - 1)))
    }

    /// The original bug: with the zone only as deep as the notch, a pointer resting
    /// just below the menu bar — where a hand travelling up naturally stops — missed
    /// it entirely, so the band appeared to answer only at the notch's bottom edge.
    func testAPointerJustBelowTheMenuBarStillCounts() {
        let justBelow = CGPoint(x: screen.midX, y: screen.maxY - geometry.notchHeight - 6)
        XCTAssertTrue(zone.contains(justBelow))
    }

    /// The whole notch, not just its middle: the wings either side of the camera
    /// housing are part of the target.
    func testTheWholeNotchAndItsWingsAreInTheZone() {
        for offset in [-120.0, -60.0, 0.0, 60.0, 120.0] {
            let point = CGPoint(x: screen.midX + offset, y: screen.maxY - 8)
            XCTAssertTrue(zone.contains(point), "offset \(offset) should be on the notch")
        }
    }

    /// …but not so wide that reaching for the clock or the app menu opens it.
    func testTheMenuBarsOwnItemsStayOutsideTheZone() {
        XCTAssertFalse(zone.contains(CGPoint(x: screen.maxX - 40, y: screen.maxY - 8)),
                       "the clock / status icons")
        XCTAssertFalse(zone.contains(CGPoint(x: 120, y: screen.maxY - 8)),
                       "the app menu")
    }

    /// Nothing far down the screen is ever "near the notch".
    func testTheZoneDoesNotReachIntoWindowContent() {
        XCTAssertFalse(zone.contains(CGPoint(x: screen.midX, y: screen.maxY - 120)))
    }

    // MARK: - While it's open

    private var panelFrame: CGRect {
        let size = layout.panelSize(for: geometry, rows: 2)
        return CGRect(origin: CGPoint(x: screen.midX - size.width / 2,
                                      y: screen.maxY - size.height),
                      size: size)
    }

    /// The reach from the notch down into the band has to be continuous — every point
    /// on the way keeps it open, so the close grace is a safety net rather than the
    /// thing holding the panel up.
    func testTheWholeTravelFromNotchToBandKeepsItOpen() {
        for y in stride(from: screen.maxY - 1, through: panelFrame.minY + 1, by: -4) {
            let point = CGPoint(x: screen.midX, y: y)
            XCTAssertTrue(
                layout.isPointerEngaged(point, panelFrame: panelFrame, zone: zone),
                "the pointer at y=\(y) is still on the band")
        }
    }

    func testDriftingJustOffTheBandsEdgeDoesNotClose() {
        let justOutside = CGPoint(x: panelFrame.maxX + layout.exitMargin - 2,
                                  y: panelFrame.midY)
        XCTAssertTrue(layout.isPointerEngaged(justOutside, panelFrame: panelFrame, zone: zone))
    }

    func testWellAwayFromTheBandIsNotEngaged() {
        let away = CGPoint(x: panelFrame.maxX + layout.exitMargin + 40, y: panelFrame.midY)
        XCTAssertFalse(layout.isPointerEngaged(away, panelFrame: panelFrame, zone: zone))
    }
}

/// Due-date wording in the band, which has room for three words rather than a
/// sentence.
final class NotchQuickActionsFormatTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: iso)!
    }

    func testPastDueReadsAsOverdue() {
        let now = date("2026-08-01T12:00:00Z")
        XCTAssertEqual(
            NotchQuickActionsFormat.due(date("2026-08-01T11:59:00Z"), now: now, calendar: calendar),
            "Overdue")
    }

    /// Today needs no date — the time is the whole answer.
    func testTodayShowsOnlyTheTime() {
        let now = date("2026-08-01T12:00:00Z")
        let text = NotchQuickActionsFormat.due(
            date("2026-08-01T15:30:00Z"), now: now, calendar: calendar)
        XCTAssertFalse(text.contains("Tomorrow"))
        XCTAssertFalse(text.isEmpty)
    }

    func testTomorrowIsNamed() {
        let now = date("2026-08-01T12:00:00Z")
        let text = NotchQuickActionsFormat.due(
            date("2026-08-02T09:00:00Z"), now: now, calendar: calendar)
        XCTAssertTrue(text.hasPrefix("Tomorrow"), text)
    }

    /// Inside the week a weekday is more useful than a date; past it, a date is.
    func testWithinTheWeekUsesAWeekdayAndBeyondItADate() {
        let now = date("2026-08-01T12:00:00Z")
        let midweek = NotchQuickActionsFormat.due(
            date("2026-08-05T09:00:00Z"), now: now, calendar: calendar)
        let later = NotchQuickActionsFormat.due(
            date("2026-08-20T09:00:00Z"), now: now, calendar: calendar)
        XCTAssertNotEqual(midweek, later)
        XCTAssertTrue(midweek.contains(":"), "a weekday line still carries the time: \(midweek)")
        XCTAssertFalse(later.contains(":"), "a far-off line is a date, not a time: \(later)")
    }
}
