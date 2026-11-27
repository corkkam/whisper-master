import XCTest
@testable import WhisperMaster

final class AgentFaceTests: XCTestCase {
    private func item(
        _ id: String, _ role: AgentFaceRole, _ state: AgentFaceState, group: String? = nil
    ) -> AgentRailItem {
        AgentRailItem(id: id, identity: AgentFaceIdentity(name: id, role: role), state: state,
                      discussionGroup: group)
    }

    // MARK: Looks

    func testEachStateHasADistinctLook() {
        for reduce in [false, true] {
            let looks = AgentFaceState.allCases.map { AgentFaceLook.look(for: $0, reduceMotion: reduce) }
            for i in looks.indices {
                for j in looks.indices where j > i {
                    XCTAssertNotEqual(looks[i], looks[j],
                                      "\(AgentFaceState.allCases[i]) and \(AgentFaceState.allCases[j]) look the same (reduce \(reduce))")
                }
            }
        }
    }

    /// Without colour, the eyes, brows and badge still tell the states apart
    /// for the states a person must act on.
    func testStateIsNeverColourAlone() {
        func shape(_ s: AgentFaceState) -> String {
            let l = AgentFaceLook.look(for: s, reduceMotion: true)
            return "\(l.eyes) \(l.gaze) \(l.brows) \(l.badge) \(l.orb) \(l.dotOpacity)"
        }
        let shapes = AgentFaceState.allCases.map(shape)
        XCTAssertEqual(Set(shapes).count, shapes.count)
    }

    func testReduceMotionGivesNoMotion() {
        for state in AgentFaceState.allCases {
            let l = AgentFaceLook.look(for: state, reduceMotion: true)
            XCTAssertFalse(l.moving, "\(state)")
            XCTAssertFalse(l.blinks, "\(state)")
            XCTAssertNil(l.pulse, "\(state)")
            XCTAssertNil(l.eyesSettleAfter, "\(state)")
            XCTAssertNil(l.ringFadesAfter, "\(state)")
            let plan = AgentFaceMotion.plan(
                l, blinkInterval: 7, since: Date(), clearedAt: nil, hero: true)
            XCTAssertTrue(plan.isEmpty, "\(state) still schedules redraws")
        }
    }

    func testIdleAndStillStatesDoNotMove() {
        for state in [AgentFaceState.idle, .waiting, .done, .error, .overBudget, .asleep] {
            XCTAssertFalse(AgentFaceLook.look(for: state, reduceMotion: false).moving, "\(state)")
        }
        for state in [AgentFaceState.listening, .thinking, .discussing, .working] {
            XCTAssertTrue(AgentFaceLook.look(for: state, reduceMotion: false).moving, "\(state)")
        }
    }

    func testStateToOrbFigure() {
        XCTAssertEqual(AgentFaceLook.look(for: .listening, reduceMotion: false).orb, .listening)
        XCTAssertEqual(AgentFaceLook.look(for: .thinking, reduceMotion: false).orb, .solving)
        XCTAssertEqual(AgentFaceLook.look(for: .discussing, reduceMotion: false).orb, .composing)
        XCTAssertEqual(AgentFaceLook.look(for: .working, reduceMotion: false).orb, .working)
    }

    // MARK: Time

    func testBlinkIntervalIsStableAndInRange() {
        for name in ["Atlas", "Maya", "Quinn", "", "a very long agent name", "Ünïcödé"] {
            let a = AgentFaceIdentity(name: name, role: .pm).blinkInterval
            let b = AgentFaceIdentity(name: name, role: .qa).blinkInterval
            XCTAssertEqual(a, b, name)
            XCTAssertGreaterThanOrEqual(a, 6, name)
            XCTAssertLessThanOrEqual(a, 10, name)
        }
        // Pinned, so a change to the hash (and every face's rhythm) is deliberate.
        XCTAssertEqual(AgentFaceHash.fnv1a("a"), 0xaf63_dc4c_8601_ec8c)
    }

    func testIdleBlinksOnce150msPerInterval() {
        let since = Date(timeIntervalSinceReferenceDate: 1000)
        let look = AgentFaceLook.look(for: .idle, reduceMotion: false)
        func eyes(_ t: TimeInterval) -> AgentFaceLook.Eyes {
            AgentFaceMotion.frame(look, blinkInterval: 8, since: since, clearedAt: nil,
                                  at: since.addingTimeInterval(t)).eyes
        }
        XCTAssertEqual(eyes(0.05), .open)  // no blink on entry
        XCTAssertEqual(eyes(8.05), .closed)
        XCTAssertEqual(eyes(8.2), .open)
        XCTAssertEqual(eyes(16.1), .closed)

        let plan = AgentFaceMotion.plan(look, blinkInterval: 8, since: since, clearedAt: nil, hero: false)
        XCTAssertEqual(plan.next(after: since), since.addingTimeInterval(8))
        XCTAssertEqual(plan.next(after: since.addingTimeInterval(8)), since.addingTimeInterval(8.15))
        XCTAssertEqual(plan.next(after: since.addingTimeInterval(8.15)), since.addingTimeInterval(16))
    }

    func testWaitingPulsesForTenSecondsThenHolds() {
        let since = Date(timeIntervalSinceReferenceDate: 0)
        let look = AgentFaceLook.look(for: .waiting, reduceMotion: false)
        func pulse(_ t: TimeInterval) -> Double {
            AgentFaceMotion.frame(look, blinkInterval: 7, since: since, clearedAt: nil,
                                  at: since.addingTimeInterval(t)).pulse
        }
        XCTAssertEqual(pulse(1), 1, accuracy: 1e-9)
        XCTAssertEqual(pulse(2), 0, accuracy: 1e-9)
        XCTAssertEqual(pulse(10.5), 0)

        let hero = AgentFaceMotion.plan(look, blinkInterval: 7, since: since, clearedAt: nil, hero: true)
        XCTAssertNil(hero.next(after: since.addingTimeInterval(10)), "the timeline must stop after 10 s")
        let other = AgentFaceMotion.plan(look, blinkInterval: 7, since: since, clearedAt: nil, hero: false)
        XCTAssertTrue(other.isEmpty, "only a hero pulses")
    }

    func testDoneArcsThenOpenAndRingFades() {
        let since = Date(timeIntervalSinceReferenceDate: 0)
        let look = AgentFaceLook.look(for: .done, reduceMotion: false)
        func frame(_ t: TimeInterval) -> AgentFaceFrame {
            AgentFaceMotion.frame(look, blinkInterval: 7, since: since, clearedAt: nil,
                                  at: since.addingTimeInterval(t))
        }
        XCTAssertEqual(frame(0.5).eyes, .happyArcs)
        XCTAssertEqual(frame(1.3).eyes, .open)
        XCTAssertEqual(frame(7).ringOpacity, 1)
        XCTAssertEqual(frame(9).ringOpacity, 0)
    }

    func testContextClearGathersAndBlinksOnce() {
        let at = Date(timeIntervalSinceReferenceDate: 50)
        let look = AgentFaceLook.look(for: .working, reduceMotion: false)
        let mid = AgentFaceMotion.frame(look, blinkInterval: 7, since: nil, clearedAt: at,
                                        at: at.addingTimeInterval(0.3))
        XCTAssertLessThan(mid.gather, 0.3)
        XCTAssertEqual(mid.eyes, .closed)
        let after = AgentFaceMotion.frame(look, blinkInterval: 7, since: nil, clearedAt: at,
                                          at: at.addingTimeInterval(0.7))
        XCTAssertEqual(after.gather, 1)
        XCTAssertEqual(after.eyes, .open)
    }

    // MARK: Identity

    func testEveryRoleHasABadgeAndWords() {
        for role in AgentFaceRole.allCases {
            XCTAssertEqual(role.badge.count, 2, "\(role)")
            XCTAssertFalse(role.words.isEmpty, "\(role)")
        }
        XCTAssertEqual(Set(AgentFaceRole.allCases.map(\.badge)).count, AgentFaceRole.allCases.count)
        XCTAssertEqual(AgentFaceRole.lead.silhouette, .circle)
        XCTAssertEqual(AgentFaceRole.component.silhouette, .roundedSquare)
        XCTAssertEqual(AgentFaceRole.qa.silhouette, .hexagon)
        let component = AgentFaceIdentity(name: "Parser", role: .component, componentName: "parser")
        XCTAssertEqual(component.badge, "PA")
        XCTAssertEqual(component.roleWords, "parser component agent")
    }

    func testIdentityHuesAvoidReservedStateColours() {
        XCTAssertEqual(AgentFaceHue.palette.count, 6)
        for hue in AgentFaceHue.palette {
            XCTAssertTrue(hue.avoidsReservedStateColors, "\(hue)")
            // Blue, violet and teal range.
            XCTAssertTrue((180...300).contains(hue.degrees), "\(hue)")
        }
        XCTAssertFalse(AgentFaceHue(degrees: 45, saturation: 0.7).avoidsReservedStateColors)
        XCTAssertFalse(AgentFaceHue(degrees: 220, saturation: 0.1).avoidsReservedStateColors)
    }

    func testDefaultHueIsStableAndInRange() {
        let a = AgentFaceIdentity(name: "Maya", role: .pm)
        XCTAssertEqual(a.hueIndex, AgentFaceIdentity(name: "Maya", role: .qa).hueIndex)
        XCTAssertTrue(AgentFaceHue.palette.indices.contains(a.hueIndex))
        XCTAssertEqual(AgentFaceIdentity(name: "X", role: .pm, hueIndex: -1).hue, AgentFaceHue.palette[5])
    }

    func testShortNameTruncatesToEight() {
        XCTAssertEqual(AgentFaceIdentity(name: "Designer", role: .design).shortName, "Designer")
        XCTAssertEqual(AgentFaceIdentity(name: "Tokenizer", role: .component).shortName, "Tokeniz\u{2026}")
        XCTAssertEqual(AgentFaceIdentity(name: "Tokenizer", role: .component).shortName.count, 8)
    }

    // MARK: Rail

    func testOrdering() {
        let items = [
            item("idle", .qa, .idle), item("asleep", .user, .asleep), item("work", .pm, .working),
            item("err", .architect, .error), item("lead", .lead, .asleep), item("wait", .design, .waiting),
            item("done", .marketing, .done), item("think", .qa, .thinking), item("talk", .pm, .discussing),
            item("listen", .qa, .listening),
        ]
        XCTAssertEqual(AgentRail.ordered(items).map(\.id),
                       ["lead", "wait", "err", "work", "talk", "think", "listen", "done", "idle", "asleep"])
    }

    func testOrderingIsStableForTies() {
        let items = [item("b", .qa, .working), item("a", .pm, .working)]
        XCTAssertEqual(AgentRail.ordered(items).map(\.id), ["b", "a"])
    }

    func testAtMostTwoHeroesWaitingFirst() {
        let items = AgentRail.ordered([
            item("lead", .lead, .working), item("w1", .qa, .working), item("w2", .pm, .thinking),
            item("wait", .design, .waiting),
        ])
        let heroes = AgentRail.heroes(items)
        XCTAssertEqual(heroes, ["wait", "lead"])
        XCTAssertLessThanOrEqual(heroes.count, AgentRail.maxHeroes)

        let calm = [item("lead", .lead, .idle), item("e", .qa, .error), item("z", .pm, .asleep)]
        XCTAssertTrue(AgentRail.heroes(calm).isEmpty, "still faces never take a hero slot")
    }

    func testOverflow() {
        let seven = (0..<7).map { item("a\($0)", .qa, .idle) }
        let capped = AgentRail.capped(seven)
        XCTAssertEqual(capped.visible.count, 5)
        XCTAssertEqual(capped.overflow, 2)
        let three = AgentRail.capped(Array(seven.prefix(3)))
        XCTAssertEqual(three.visible.count, 3)
        XCTAssertEqual(three.overflow, 0)
    }

    func testDiscussionLinks() {
        let visible = [
            item("a", .lead, .working), item("b", .pm, .discussing, group: "g"),
            item("c", .qa, .discussing, group: "h"), item("d", .design, .discussing, group: "g"),
            item("e", .user, .discussing, group: "g"),
        ]
        let links = AgentRail.discussionLinks(visible).map { [$0.0, $0.1] }
        XCTAssertEqual(links, [[1, 3], [3, 4]])
    }

    // MARK: Accessibility

    func testAccessibilityText() {
        let maya = AgentRailItem(id: "m", identity: AgentFaceIdentity(name: "Maya", role: .pm), state: .waiting)
        XCTAssertEqual(maya.identity.accessibilityLabel, "Maya, project manager")
        XCTAssertEqual(maya.accessibilityValue, "Waiting for approval")
        let atlas = AgentRailItem(id: "a", identity: AgentFaceIdentity(name: "Atlas", role: .lead),
                                  state: .working, detail: "tests")
        XCTAssertEqual(atlas.accessibilityValue, "Working, tests")
        XCTAssertEqual(atlas.hoverText, "Atlas \u{00B7} Lead agent \u{00B7} Working, tests")
        for state in AgentFaceState.allCases {
            XCTAssertEqual(AgentFaceLook.look(for: state, reduceMotion: false).accessibilityValue, state.words)
            XCTAssertFalse(state.words.isEmpty)
        }
        let items = [maya, atlas, item("z", .qa, .asleep)]
        XCTAssertEqual(AgentRail.accessibilityLabel(items), "Agent team, 2 active")
    }
}
