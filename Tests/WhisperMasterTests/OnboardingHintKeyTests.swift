import XCTest

@testable import WhisperMaster

/// A hint, tooltip or line names a key only where the key map does that in
/// that state, and a visible line names Escape or Command W only while the band
/// has the keyboard.
final class OnboardingHintKeyTests: XCTestCase {
    private let cases = OnboardingCopyCases.self

    private func escape(_ row: OnboardingRow) -> OnboardingKeyAction {
        OnboardingReturnTarget.resolve(.escape, row: row, focused: nil, backEnabled: true, voiceOver: false)
    }

    /// "Or press Escape" sits only on the button Escape presses. In prompt up the
    /// system's alert may hold the keyboard, and the key-panel check on real
    /// hardware has not kept the hint, so the test expects none there.
    func testEscapeHintsSitOnlyOnTheButtonEscapePresses() {
        for copy in cases.copies {
            for state in cases.states {
                let row = copy.screen(state).row
                for (index, button) in row.buttons.enumerated() {
                    let hint = copy.hint(for: button, in: state) ?? ""
                    let pressed = escape(row) == .press(index == 0 ? .main : .second)
                    let named = hint.contains("Escape")
                    if state == .micPromptUp {
                        XCTAssertFalse(named, "\(state) \(button): \(hint)")
                    } else {
                        XCTAssertEqual(named, pressed, "\(state) \(button): \(hint)")
                    }
                }
            }
        }
    }

    func testPressEscapeToStayOnlyWhereEscapeStopsTheWait() {
        for state in cases.states {
            let row = OnboardingCopy().screen(state).row
            for key in [false, true] {
                // The line shows only in a moving-on row.
                guard case .badge(_, .movingOn) = row else { continue }
                let line = OnboardingCopy.movingOnLine(panelIsKey: key)
                for text in [line.text, line.fallback ?? ""] {
                    XCTAssertEqual(text.contains("Press Escape to stay"), key, "\(state): \(text)")
                }
                XCTAssertEqual(escape(row), .cancelAutoAdvance)
            }
        }
    }

    func testLeftArrowOnlyWhereBackIsEnabled() {
        for enabled in [false, true] {
            let tooltip = OnboardingCopy.backTooltip(enabled: enabled)
            let hint = OnboardingCopy.backHint(enabled: enabled) ?? ""
            let named = tooltip.contains("←") || hint.contains("Left Arrow")
            let key = OnboardingReturnTarget.resolve(
                .leftArrow, row: .buttons([.notNow]), focused: nil, backEnabled: enabled, voiceOver: false)
            XCTAssertEqual(named, key == .press(.back))
        }
    }

    func testCloseNamesCommandWAndCommandWCloses() {
        XCTAssertTrue(OnboardingCopy.closeTooltip.contains("⌘W"))
        XCTAssertTrue(OnboardingCopy.closeHint.contains("Command W"))
        for state in cases.states {
            let row = OnboardingCopy().screen(state).row
            XCTAssertEqual(
                OnboardingReturnTarget.resolve(.closeWindow, row: row, focused: nil, backEnabled: false, voiceOver: true),
                .press(.close))
        }
    }

    func testWithoutTheKeyboardNoVisibleLineNamesEscapeOrCommandW() {
        for copy in cases.copies {
            for context in cases.topBarContexts where !context.panelIsKey {
                guard let line = copy.topBarLine(context) else { continue }
                for text in [line.text, line.fallback ?? ""] {
                    XCTAssertFalse(text.contains("Escape") || text.contains("Command W"), text)
                }
            }
        }
        let line = OnboardingCopy.movingOnLine(panelIsKey: false)
        XCTAssertFalse(line.text.contains("Escape") || (line.fallback ?? "").contains("Escape"))
    }

    /// Keys belong in hints, the top-bar line, the moving-on line and the
    /// tooltips, which follow the keyboard. A headline or body names none.
    func testNoHeadlineOrBodyNamesABandKey() {
        for copy in cases.copies {
            for state in cases.states {
                let screen = copy.screen(state)
                for text in [screen.headline, screen.body, screen.fallbackBody ?? ""] {
                    for key in ["Escape", "Command W", "⌘W", "Left Arrow", "←"] {
                        XCTAssertFalse(text.contains(key), "\(state): \(text)")
                    }
                }
            }
        }
    }

    func testNoStringNamesReturn() {
        for copy in cases.copies {
            for (source, text) in OnboardingCopyCases.allStrings(copy) {
                XCTAssertFalse(text.contains("Return"), "\(source): \(text)")
                XCTAssertFalse(text.contains("Enter"), "\(source): \(text)")
            }
        }
    }
}
