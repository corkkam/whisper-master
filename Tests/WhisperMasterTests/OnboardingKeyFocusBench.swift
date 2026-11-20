import AppKit
import SwiftUI
import XCTest

@testable import WhisperMaster

/// The key panel's rules, and a bench for keyboard focus in a real key window.
///
/// The bench needs a window server, a panel that really becomes key, and
/// macOS keyboard navigation (Tab reaching buttons). Where any of the three is
/// missing it skips, never fails: a headless run or a default keyboard setting
/// is not a bug in the band.
@MainActor
final class OnboardingKeyFocusBench: XCTestCase {
    private let full = OnboardingMotionPolicy.resolve(reduceMotion: false, lowPower: false, thermal: .nominal, voiceOver: false)

    func testThePanelBecomesKeyOnlyWhileTheAppIsActive() {
        let panel = OnboardingKeyPanel()
        panel.isActive = { false }
        XCTAssertFalse(panel.canBecomeKey)
        panel.isActive = { true }
        XCTAssertTrue(panel.canBecomeKey)
    }

    /// When our app becomes active with Settings key, setup leaves the keyboard
    /// with Settings, so a Return meant for it cannot press a band button. With
    /// no key window, or with the band already key (back from System
    /// Settings), setup takes it.
    func testOnActivationSetupTakesTheKeyboardOnlyWhenNoOtherWindowHasIt() {
        let band = OnboardingKeyPanel()
        let stage = OnboardingKeyPanel()
        let settings = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
        XCTAssertFalse(OnboardingKeyPanel.takesKeyboardOnActivation(keyWindow: settings, ours: [band, stage]))
        XCTAssertTrue(OnboardingKeyPanel.takesKeyboardOnActivation(keyWindow: nil, ours: [band]))
        XCTAssertTrue(OnboardingKeyPanel.takesKeyboardOnActivation(keyWindow: band, ours: [band]))
        XCTAssertTrue(OnboardingKeyPanel.takesKeyboardOnActivation(keyWindow: stage, ours: [band, stage]))
    }

    func testFocusOnNotNowSurvivesATransition() throws {
        var now: TimeInterval = 1_000
        let model = NotchOnboardingModel(
            permissions: FakePermissions(),
            capture: FakeCapture(),
            clock: OnboardingClock(now: { now }, isFixed: false),
            engineStatus: { .ready },
            onComplete: { _ in },
            onDismiss: {})
        let panel = OnboardingKeyPanel()
        panel.isActive = { true }
        let host = NSHostingView(rootView: NotchOnboardingView(model: model, state: AppState()))
        panel.contentView = host
        panel.setFrame(NSRect(x: 80, y: 80, width: 460, height: 300), display: true)
        defer {
            panel.orderOut(nil)
            panel.contentView = nil
        }

        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        model.begin(.reveal, policy: full)
        panel.makeKeyAndOrderFront(nil)
        settle()
        guard panel.isKeyWindow else { throw XCTSkip("No window server, or the panel did not become key.") }

        // Tab until Not now has focus. Keyboard navigation off: Tab reaches no button.
        for _ in 0..<8 where model.focusedAction != .second {
            let tab = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            panel.sendEvent(tab)
            settle()
        }
        guard model.focusedAction == .second else {
            throw XCTSkip("Tab did not reach the buttons; keyboard navigation is likely off.")
        }
        let responder = panel.firstResponder

        // The reveal ends: the band's timeline pauses at rest.
        now += 2
        XCTAssertGreaterThan(now, model.activeUntil)
        settle()
        XCTAssertTrue(panel.firstResponder === responder)
        XCTAssertEqual(model.focusedAction, .second)
    }
}
