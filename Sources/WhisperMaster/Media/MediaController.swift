import Foundation

/// Carries out a spoken transport command.
///
/// **Play and pause are checked against the world before they are sent**, because
/// the key is a toggle: "pause" while nothing is playing would *start* the music,
/// which is the opposite of what was asked and the single worst outcome this whole
/// area has. Next and previous are safe to send blind — they act on the same
/// now-playing app either way and cannot flip a state.
@MainActor
enum MediaController {
    /// - Returns: whether anything was sent. `false` means the world was already the
    ///   way the user asked for — worth saying back, since silence would read as the
    ///   command having been missed.
    @discardableResult
    static func perform(_ command: MediaCommand, ownBundleID: String = Bundle.main.bundleIdentifier ?? "") async -> Bool {
        switch command {
        case .next:
            MediaKey.send(.next)
            return true
        case .previous:
            MediaKey.send(.previous)
            return true
        case .play, .pause:
            let playing = !(await MediaPlaybackState.playingApps(ownBundleID: ownBundleID)).isEmpty
            let wantsPlaying = command == .play
            guard playing != wantsPlaying else { return false }
            MediaKey.send(.playPause)
            return true
        }
    }
}
