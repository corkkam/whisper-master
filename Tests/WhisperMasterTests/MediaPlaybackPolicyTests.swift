import XCTest

@testable import WhisperMaster

/// The allowlist is the only guard between "pause the podcast" and "start the music
/// you deliberately stopped before a meeting", because the play/pause key is a
/// toggle aimed at whichever app macOS calls now-playing. These pin the cases that
/// decide which of the two happens.
final class MediaPlaybackPolicyTests: XCTestCase {
    private let ownBundleID = "app.whispermaster.mac"

    func testPausesForAKnownPlayer() {
        XCTAssertTrue(MediaPlaybackPolicy.shouldPause(
            runningOutput: ["com.spotify.client"], ownBundleID: ownBundleID))
    }

    /// The process holding a browser's audio stream is a helper, so an exact-match
    /// list would never fire for the commonest case there is: a video in a tab.
    func testPausesForABrowserHelperProcess() {
        XCTAssertTrue(MediaPlaybackPolicy.shouldPause(
            runningOutput: ["com.google.Chrome.helper"], ownBundleID: ownBundleID))
    }

    /// Safari and every other WKWebView player render their audio through one shared
    /// GPU process, which is what actually shows up as running output.
    func testPausesForTheSharedWebKitAudioProcess() {
        XCTAssertTrue(MediaPlaybackPolicy.shouldPause(
            runningOutput: ["com.apple.WebKit.GPU"], ownBundleID: ownBundleID))
    }

    /// A call is the case that must never be touched: the key would not pause it, and
    /// the app that answers instead is whatever music is sitting paused.
    func testIgnoresConferencingApps() {
        XCTAssertFalse(MediaPlaybackPolicy.shouldPause(
            runningOutput: ["us.zoom.xos", "com.microsoft.teams2", "com.hnc.Discord"],
            ownBundleID: ownBundleID))
    }

    /// A command-line tool has no bundle identifier and does not answer media keys.
    func testIgnoresProcessesWithNoBundleIdentifier() {
        XCTAssertFalse(MediaPlaybackPolicy.shouldPause(
            runningOutput: ["", ""], ownBundleID: ownBundleID))
    }

    /// Reading an answer aloud is our own voice. Pausing for it would mean the app
    /// pressing play/pause at itself every time it spoke.
    func testIgnoresOurOwnPlayback() {
        XCTAssertFalse(MediaPlaybackPolicy.shouldPause(
            runningOutput: ["app.whispermaster.mac"], ownBundleID: ownBundleID))
    }

    /// The beta and dev channels ship under suffixed identifiers, and each build
    /// reports its own — so the match is a prefix rather than a literal.
    func testIgnoresOurOwnPlaybackOnAChannelBuild() {
        XCTAssertFalse(MediaPlaybackPolicy.shouldPause(
            runningOutput: ["app.whispermaster.mac.beta"],
            ownBundleID: "app.whispermaster.mac.beta"))
    }

    /// One recognised player among unrecognised noise is still worth a press.
    func testPausesWhenOnePlayerIsMixedWithUnknownAudio() {
        XCTAssertTrue(MediaPlaybackPolicy.shouldPause(
            runningOutput: ["us.zoom.xos", "", "com.apple.Music"], ownBundleID: ownBundleID))
    }

    func testNothingPlayingNeedsNoPress() {
        XCTAssertFalse(MediaPlaybackPolicy.shouldPause(
            runningOutput: [], ownBundleID: ownBundleID))
    }
}
