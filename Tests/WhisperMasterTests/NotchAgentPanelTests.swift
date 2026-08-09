import XCTest

@testable import WhisperMaster

/// The band's height has to be decided *before* the card lays out, so the thickness
/// math and the card's own frames are two statements of one number. When they
/// disagreed, the band clipped its own content: the context row underneath the
/// choice card was cut in half. These are the regression checks on that.
@MainActor
final class NotchAgentPanelTests: XCTestCase {

    private let banner: CGFloat = 58

    private func choice(options: [String], multiSelect: Bool = false) -> AgentAsk {
        .choice(
            AgentChoice(
                requestID: "r",
                questions: [
                    .init(text: "Q", header: nil, multiSelect: multiSelect, options: options)
                ],
                context: "repo"))
    }

    private var approval: AgentAsk {
        .approval(AgentApproval(requestID: "r", tool: "Bash", headline: "Run ls", detail: "repo"))
    }

    func testAChoiceBandIsTallEnoughForTheCardItHolds() {
        let ask = choice(options: ["one", "two", "three"])
        let thickness = NotchAgentPanel.thickness(for: ask, otherSessions: 0, banner: banner)
        XCTAssertEqual(thickness, NotchAgentChoiceCard.Metrics.height(optionCount: 3))
    }

    func testTheBandGrowsARowPerOption() {
        let two = NotchAgentPanel.thickness(
            for: choice(options: ["a", "b"]), otherSessions: 0, banner: banner)
        let three = NotchAgentPanel.thickness(
            for: choice(options: ["a", "b", "c"]), otherSessions: 0, banner: banner)
        XCTAssertEqual(
            three - two,
            NotchAgentChoiceCard.Metrics.optionRow + NotchAgentChoiceCard.Metrics.spacing)
    }

    func testTheContextRowIsOnlyChargedWhenThereIsOne() {
        let alone = NotchAgentPanel.thickness(for: approval, otherSessions: 0, banner: banner)
        let withOthers = NotchAgentPanel.thickness(for: approval, otherSessions: 2, banner: banner)
        XCTAssertEqual(alone, banner)
        XCTAssertEqual(withOthers, banner + NotchAgentPanel.contextRowHeight)
    }

    func testTheDeferredChoiceFallsBackToABannerHeight() {
        // An option too long to show honestly renders as a plain deferral row, so it
        // must not reserve a full card's worth of band.
        let long = String(repeating: "x", count: 200)
        let thickness = NotchAgentPanel.thickness(
            for: choice(options: [long]), otherSessions: 0, banner: banner)
        XCTAssertEqual(thickness, banner)
    }

    func testThePanelNeverExceedsWhatTheWindowWasSizedFor() {
        // The panel is sized once at window creation, so a band taller than
        // `maxThickness` would be clipped by its own window.
        let fullest = choice(
            options: ["a", "b", "c", "d", "e"], multiSelect: true)  // more than fit
        let thickness = NotchAgentPanel.thickness(
            for: fullest, otherSessions: 3, banner: banner)
        XCTAssertLessThanOrEqual(thickness, NotchAgentPanel.maxThickness)
    }

    // MARK: The glance

    func testTheGlanceGrowsARowPerSessionAndStopsAtItsCap() {
        let two = NotchAgentGlance.listThickness(sessionCount: 2)
        let three = NotchAgentGlance.listThickness(sessionCount: 3)
        XCTAssertEqual(
            three - two,
            NotchAgentGlance.Metrics.row + NotchAgentGlance.Metrics.rowSpacing)

        // Past the cap it stops growing per session and charges one "+N more" row,
        // rather than a band that scales with however many agents are running.
        let many = NotchAgentGlance.listThickness(sessionCount: 40)
        XCTAssertLessThanOrEqual(many, NotchAgentGlance.maxThickness)
    }

    func testAnEmptyGlanceStillHasABandToPutASentenceIn() {
        // It opened because the user asked it to, so it owes them a line rather than
        // a zero-height band.
        XCTAssertGreaterThan(NotchAgentGlance.listThickness(sessionCount: 0), 0)
    }

    func testTheSessionViewIsBoundedByWhatTheWindowWasSizedFor() {
        let tallest = NotchAgentSessionView.thickness(
            lineCount: 99, hasChanges: true)
        XCTAssertEqual(tallest, NotchAgentSessionView.maxThickness)
        XCTAssertLessThanOrEqual(tallest, NotchAgentGlance.maxThickness)
    }

    func testTheChangedFilesRowIsOnlyChargedWhenThereAreSome() {
        let without = NotchAgentSessionView.thickness(lineCount: 3, hasChanges: false)
        let with = NotchAgentSessionView.thickness(lineCount: 3, hasChanges: true)
        XCTAssertEqual(
            with - without,
            NotchAgentSessionView.Metrics.line + NotchAgentSessionView.Metrics.spacing)
    }

    // MARK: Panel

    func testTheAskingSessionIsNotRepeatedUnderneathItsOwnQuestion() {
        let sessions = [
            AgentSession(id: "s1", repo: "whisper-master", state: .awaitingPermission),
            AgentSession(id: "s2", repo: "kunai", state: .running),
        ]
        let others = NotchAgentPanel.otherSessions(in: sessions, askingRepo: "whisper-master")
        XCTAssertEqual(others.map(\.repo), ["kunai"])
    }

    func testASecondSessionInTheSameRepoIsStillShown() {
        // Two sessions can share a checkout (kunai runs several agents on one repo
        // via worktrees). Only the one actually asking is folded away.
        let sessions = [
            AgentSession(id: "s1", repo: "whisper-master", state: .awaitingPermission),
            AgentSession(id: "s2", repo: "whisper-master", state: .running),
        ]
        let others = NotchAgentPanel.otherSessions(in: sessions, askingRepo: "whisper-master")
        XCTAssertEqual(others.map(\.id), ["s2"])
    }
}
