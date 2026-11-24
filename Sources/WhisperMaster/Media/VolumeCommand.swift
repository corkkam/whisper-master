import AppKit

/// What the user asked the output volume to do.
enum VolumeCommand: Equatable, Sendable {
    case up
    case down
    case mute
    case unmute
    /// An absolute level, 0 to 100.
    case set(Int)

    /// The banner line after it is done. Short: the HUD or the sound already says it.
    var confirmation: String {
        switch self {
        case .up: return "Volume up"
        case .down: return "Volume down"
        case .mute: return "Muted"
        case .unmute: return "Unmuted"
        case .set(let level): return "Volume \(level)%"
        }
    }
}

/// Reads "volume up" and "set the volume to 30" out of a spoken assistant capture.
///
/// **⚠️ This is legal only downstream of the assistant chord**, in
/// `routeCommandCapture`, for the reason `MediaCommandDetector` is: that path has
/// already suppressed the paste. Run over an ordinary dictation it would eat "turn it
/// up" out of the user's sentence and type nothing. `VolumeCommandTests` scans the
/// source for any other call. Do not call it from anywhere else.
///
/// The **whole** capture must be the command, and every slot is closed: a fixed list of
/// phrases, or the word "volume" and a number from 0 to 100. "Turn up the heat" and
/// "mute the music" (a pause, `MediaCommandDetector`) are not volume commands.
enum VolumeCommandDetector {
    private static let phrases: [(VolumeCommand, [String])] = [
        (.up, [
            "volume up", "turn the volume up", "turn up the volume", "turn it up",
            "raise the volume", "increase the volume", "louder", "make it louder",
        ]),
        (.down, [
            "volume down", "turn the volume down", "turn down the volume", "turn it down",
            "lower the volume", "decrease the volume", "quieter", "make it quieter",
        ]),
        (.mute, ["mute", "mute it", "mute the volume", "mute the sound"]),
        (.unmute, ["unmute", "unmute it", "unmute the volume", "unmute the sound"]),
    ]

    /// The command this capture *is*, or nil when it is anything else.
    static func detect(_ text: String) -> VolumeCommand? {
        let words = normalize(text)
        guard !words.isEmpty else { return nil }
        for (command, spellings) in phrases where spellings.contains(words) { return command }
        return level(words).map(VolumeCommand.set)
    }

    /// "volume 50", "set the volume to 30 percent": an optional "set", an optional
    /// "the", "volume", an optional "to" or "at", and a number up to 100.
    private static func level(_ words: String) -> Int? {
        var tokens = words.split(separator: " ").map(String.init)
        if tokens.first == "set" { tokens.removeFirst() }
        if tokens.first == "the" { tokens.removeFirst() }
        guard tokens.first == "volume" else { return nil }
        tokens.removeFirst()
        if tokens.first == "to" || tokens.first == "at" { tokens.removeFirst() }
        if tokens.count == 2, tokens[1] == "percent" { tokens.removeLast() }
        guard tokens.count == 1, let level = Int(tokens[0]), (0...100).contains(level) else { return nil }
        return level
    }

    /// Lowercase and single-spaced, with punctuation read as a space: "Volume 50%." is
    /// "volume 50", and "volume 5.5" is not a level.
    private static func normalize(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }
}

/// Carries out a spoken volume command.
///
/// A step presses the keyboard's own volume key, the way `MediaKey` presses play and
/// pause. Mute and an exact level go through the scripting addition that ships with
/// macOS (`set volume …`): it runs inside this process, sends no Apple Event to another
/// app and needs no automation entitlement (checked under the hardened runtime). It is
/// used for mute rather than the mute key, because that key is a toggle and "mute"
/// said twice must not unmute.
///
/// **⚠️ Nothing here sets a Core Audio property or names a device.** `Audio/CLAUDE.md`
/// forbids that, and this is the same call the menu bar's volume slider makes. The two
/// volume keys are not the play/pause toggle, so `Media/CLAUDE.md`'s rule about
/// presses during a hold is not in play: the chord was released before this runs.
@MainActor
enum VolumeController {
    /// A key press is one sixteenth of the range, which is hard to hear alone.
    static let pressesPerStep = 2

    /// The script a command runs, or nil for a step (a key press).
    static func script(for command: VolumeCommand) -> String? {
        switch command {
        case .up, .down: return nil
        case .mute: return "set volume with output muted"
        case .unmute: return "set volume without output muted"
        // Setting a level on a muted Mac would stay silent otherwise.
        case .set(let level): return "set volume output volume \(min(max(level, 0), 100)) without output muted"
        }
    }

    /// - Returns: whether it was sent. A Mac whose output has no software volume (some
    ///   displays) refuses the script, and then the answer is no.
    @discardableResult
    static func perform(_ command: VolumeCommand,
                        sendKey: @MainActor (MediaKey.Key) -> Void = { MediaKey.send($0) },
                        runScript: @MainActor (String) -> Bool = { runAppleScript($0) }) -> Bool {
        if let source = script(for: command) { return runScript(source) }
        let key: MediaKey.Key = command == .up ? .soundUp : .soundDown
        for _ in 0..<pressesPerStep { sendKey(key) }
        return true
    }

    static func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }
}
