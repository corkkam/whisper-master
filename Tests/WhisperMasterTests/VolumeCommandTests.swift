import XCTest

@testable import WhisperMaster

/// A spoken volume command runs only downstream of the assistant chord, with no model,
/// so the whole capture has to *be* the command. A dictation made with the
/// push-to-talk key must never reach the detector: it would eat "turn it up" out of the
/// user's sentence.
@MainActor
final class VolumeCommandTests: XCTestCase {
    // MARK: - The matcher

    func testEachPhraseIsItsCommand() {
        let expected: [(String, VolumeCommand)] = [
            ("volume up", .up), ("Volume up.", .up), ("turn it up", .up), ("louder", .up),
            ("turn the volume up", .up), ("turn up the volume", .up),
            ("volume down", .down), ("turn it down", .down), ("quieter", .down),
            ("mute", .mute), ("Mute.", .mute), ("mute the sound", .mute),
            ("unmute", .unmute), ("Unmute it", .unmute),
            ("set the volume to 30", .set(30)), ("Set the volume to 30.", .set(30)),
            ("set volume to 30", .set(30)), ("volume 50 percent", .set(50)),
            ("Volume 50%.", .set(50)), ("volume 70", .set(70)),
            ("set the volume to 100 percent", .set(100)), ("volume 0", .set(0)),
        ]
        for (text, command) in expected {
            XCTAssertEqual(VolumeCommandDetector.detect(text), command, text)
        }
    }

    /// The line between a command and a note that mentions one.
    func testOnlyAWholeCaptureIsACommand() {
        for text in ["turn up the heat", "turn it up a notch", "remind me to turn it up",
                     "mute the music", "mute the call and take notes", "volume",
                     "set the volume", "set the volume to loud", "volume 101", "volume 5.5",
                     "volume 1,000", "the volume of the speaker is too high",
                     "turn up", "up", "", "   "] {
            XCTAssertNil(VolumeCommandDetector.detect(text), text)
        }
    }

    /// `routeCommandCapture` asks the media detector first, so a phrase both claimed
    /// would never reach the volume path.
    func testNoVolumePhraseIsAlsoAMediaCommand() {
        for text in ["volume up", "turn it up", "louder", "volume down", "turn it down",
                     "mute", "mute it", "mute the sound", "unmute", "volume 30",
                     "set the volume to 30"] {
            XCTAssertNotNil(VolumeCommandDetector.detect(text), text)
            XCTAssertNil(MediaCommandDetector.detect(text), "\(text) is taken by the media path")
        }
        XCTAssertNil(VolumeCommandDetector.detect("mute the music"), "that one is a pause")
    }

    // MARK: - Where it may run

    /// The matcher is legal in exactly one place: inside `routeCommandCapture`, which
    /// only the held fn+control chord reaches. Nothing on the push-to-talk path may
    /// call it.
    func testOnlyRouteCommandCaptureCallsTheMatcher() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WhisperMaster")
        let call = "VolumeCommandDetector.detect("
        var callers: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            if try String(contentsOf: file, encoding: .utf8).contains(call) {
                callers.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(callers, ["DictationViewModel.swift"])

        let model = try String(
            contentsOf: sources.appendingPathComponent("App/DictationViewModel.swift"), encoding: .utf8)
        let declaration = try XCTUnwrap(model.range(of: "private func routeCommandCapture("))
        // The next method at the same indentation ends the function.
        let end = model.range(of: "\n    private func ", range: declaration.upperBound..<model.endIndex)
            ?? model.range(of: "\n    func ", range: declaration.upperBound..<model.endIndex)
        let body = model[declaration.lowerBound..<(end?.lowerBound ?? model.endIndex)]
        XCTAssertEqual(body.components(separatedBy: call).count - 1, 1,
                       "the one call is inside routeCommandCapture")
        XCTAssertEqual(model.components(separatedBy: call).count - 1, 1)
    }

    // MARK: - Carrying it out

    private final class Recorder {
        var keys: [MediaKey.Key] = []
        var scripts: [String] = []
    }

    private func perform(_ command: VolumeCommand, scriptWorks: Bool = true,
                         recorder: Recorder) -> Bool {
        VolumeController.perform(command,
                                 sendKey: { recorder.keys.append($0) },
                                 runScript: { recorder.scripts.append($0); return scriptWorks })
    }

    func testAStepPressesTheVolumeKeyAndRunsNoScript() {
        let up = Recorder()
        XCTAssertTrue(perform(.up, recorder: up))
        XCTAssertEqual(up.keys, Array(repeating: .soundUp, count: VolumeController.pressesPerStep))
        XCTAssertTrue(up.scripts.isEmpty)

        let down = Recorder()
        XCTAssertTrue(perform(.down, recorder: down))
        XCTAssertEqual(down.keys, Array(repeating: .soundDown, count: VolumeController.pressesPerStep))
        XCTAssertTrue(down.scripts.isEmpty)
    }

    /// The mute key is a toggle, so "mute" said twice would unmute. The script is not.
    func testMuteAndAnExactLevelRunAScriptAndPressNoKey() {
        let recorder = Recorder()
        XCTAssertTrue(perform(.mute, recorder: recorder))
        XCTAssertTrue(perform(.unmute, recorder: recorder))
        XCTAssertTrue(perform(.set(30), recorder: recorder))
        XCTAssertEqual(recorder.scripts, [
            "set volume with output muted",
            "set volume without output muted",
            "set volume output volume 30 without output muted",
        ])
        XCTAssertTrue(recorder.keys.isEmpty)
    }

    func testALevelIsClampedAndARefusedScriptIsReported() {
        XCTAssertEqual(VolumeController.script(for: .set(250)),
                       "set volume output volume 100 without output muted")
        XCTAssertEqual(VolumeController.script(for: .set(-4)),
                       "set volume output volume 0 without output muted")
        XCTAssertFalse(perform(.set(30), scriptWorks: false, recorder: Recorder()),
                       "an output with no software volume says no")
    }

    func testTheKeyCodesAreTheSystemVolumeKeys() {
        XCTAssertEqual(MediaKey.Key.soundUp.rawValue, 0)    // NX_KEYTYPE_SOUND_UP
        XCTAssertEqual(MediaKey.Key.soundDown.rawValue, 1)  // NX_KEYTYPE_SOUND_DOWN
    }

    func testTheConfirmationNamesTheLevel() {
        XCTAssertEqual(VolumeCommand.set(30).confirmation, "Volume 30%")
        XCTAssertEqual(VolumeCommand.mute.confirmation, "Muted")
        XCTAssertEqual(VolumeCommand.up.confirmation, "Volume up")
    }
}
