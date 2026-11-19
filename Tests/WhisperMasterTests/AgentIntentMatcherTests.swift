import XCTest

@testable import WhisperMaster

/// The fast path runs only downstream of the assistant chord, and acts with no model.
/// So the whole capture has to *be* the command, and every slot is closed: an app the
/// Mac really has, or a bare domain. Anything else goes to the agent as before.
final class AgentIntentMatcherTests: XCTestCase {
    private let apps = [
        InstalledApp(name: "Figma", url: URL(fileURLWithPath: "/Applications/Figma.app")),
        InstalledApp(name: "Visual Studio Code",
                     url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app")),
        InstalledApp(name: "Calendar", url: URL(fileURLWithPath: "/System/Applications/Calendar.app")),
        InstalledApp(name: "Slack", url: URL(fileURLWithPath: "/Applications/Slack.app")),
    ]

    private func match(_ text: String) -> AgentIntent? {
        AgentIntentMatcher.match(text) { InstalledApps.match($0, in: self.apps) }
    }

    // MARK: - Apps

    func testAnInstalledAppIsOpened() {
        XCTAssertEqual(match("open Figma"), .openApp(apps[0]))
        XCTAssertEqual(match("Open Figma."), .openApp(apps[0]), "the formatter's capital and full stop")
        XCTAssertEqual(match("launch figma"), .openApp(apps[0]))
        XCTAssertEqual(match("switch to Slack"), .openApp(apps[3]))
        XCTAssertEqual(match("go to Slack"), .openApp(apps[3]))
        XCTAssertEqual(match("open visual studio code"), .openApp(apps[1]))
    }

    func testTheArticleAndTheWordAppAreNotPartOfTheName() {
        XCTAssertEqual(match("open the calendar app"), .openApp(apps[2]))
        XCTAssertEqual(match("Open the Calendar."), .openApp(apps[2]))
        XCTAssertEqual(match("please open Figma"), .openApp(apps[0]))
    }

    /// The slot is closed: a name the Mac does not have is not an app to open.
    func testAnAppThatIsNotInstalledIsNotMatched() {
        XCTAssertNil(match("open Photoshop"))
        XCTAssertNil(match("open the pod bay doors"))
        XCTAssertNil(match("launch the rocket"))
    }

    /// The line between a command and a note that mentions one.
    func testTheWholeCaptureMustBeTheCommand() {
        XCTAssertNil(match("open Figma and share the file with Sam"))
        XCTAssertNil(match("remind me to open Figma tomorrow"))
        XCTAssertNil(match("can you open Figma"))
        XCTAssertNil(match("open"))
        XCTAssertNil(match(""))
        XCTAssertNil(match("Figma"))
    }

    // MARK: - Sites

    func testASpokenDomainBecomesAnHTTPSLink() {
        XCTAssertEqual(match("go to github.com"), .openURL(URL(string: "https://github.com")!))
        XCTAssertEqual(match("Go to github.com."), .openURL(URL(string: "https://github.com")!))
        XCTAssertEqual(match("go to github dot com"), .openURL(URL(string: "https://github.com")!))
        XCTAssertEqual(match("open news.ycombinator.com"),
                       .openURL(URL(string: "https://news.ycombinator.com")!))
    }

    /// Only a bare domain fills the slot: no path, no query, no other scheme, no
    /// address the user cannot read at a glance.
    func testTheSiteSlotIsClosed() {
        XCTAssertNil(match("go to the store"))
        XCTAssertNil(match("go to bed"))
        XCTAssertNil(match("go to github.com/settings"))
        XCTAssertNil(match("go to github.com?tab=1"))
        XCTAssertNil(match("go to javascript:alert(1)"))
        XCTAssertNil(match("go to file:///etc/passwd"))
        XCTAssertNil(match("go to localhost"))
        XCTAssertNil(match("go to 192.168.1.1"))
        XCTAssertNil(match("go to user@github.com"))
    }
}
