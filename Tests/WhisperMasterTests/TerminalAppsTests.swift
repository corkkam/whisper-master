import XCTest

@testable import WhisperMaster

final class TerminalAppsTests: XCTestCase {
    func testKnownTerminalsAreRecognized() {
        XCTAssertTrue(TerminalApps.isTerminal(bundleID: "com.apple.Terminal"))
        XCTAssertTrue(TerminalApps.isTerminal(bundleID: "com.googlecode.iterm2"))
        XCTAssertTrue(TerminalApps.isTerminal(bundleID: "com.mitchellh.ghostty"))
        XCTAssertTrue(TerminalApps.isTerminal(bundleID: "dev.warp.Warp-Stable"))
        XCTAssertTrue(TerminalApps.isTerminal(bundleID: "net.kovidgoyal.kitty"))
    }

    func testNonTerminalsAreNotRecognized() {
        XCTAssertFalse(TerminalApps.isTerminal(bundleID: "com.apple.Safari"))
        XCTAssertFalse(TerminalApps.isTerminal(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(TerminalApps.isTerminal(bundleID: "com.apple.dt.Xcode"))
        XCTAssertFalse(TerminalApps.isTerminal(bundleID: ""))
    }

    func testNilBundleIDIsNotTerminal() {
        XCTAssertFalse(TerminalApps.isTerminal(bundleID: nil))
    }

    func testMatchIsExactNotSubstring() {
        // Guard against a lazy `contains`-style match: a bundle id that merely
        // embeds a known one must not register as a terminal.
        XCTAssertFalse(TerminalApps.isTerminal(bundleID: "com.apple.Terminal.helper"))
        XCTAssertFalse(TerminalApps.isTerminal(bundleID: "com.example.iterm2clone"))
    }
}
