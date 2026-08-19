import Foundation

/// "Is media playing right now, and is it something the play/pause key reaches?"
///
/// The one place that joins the Core Audio read to the allowlist, so every caller
/// asks the same question the same way — and always off the main actor, since a
/// sample costs about 1.8 ms of IPC with `coreaudiod`.
///
/// **⚠️ The answer is honest but late.** A player keeps its output stream alive for
/// roughly 3.5 seconds after it stops, so for a few seconds after the user pauses
/// their own music this still says "playing". Nothing in the public API can tell
/// the two apart — MediaRemote could, and refuses commands from unentitled
/// processes since macOS 15.4 (verified on this machine: it reports "not playing"
/// while a player is audibly running). Every caller therefore has to be safe
/// against a stale yes: `MediaPauser` presses once and then watches for the stream
/// to go quiet, and `MediaController` re-checks before it acts.
enum MediaPlaybackState {
    /// Bundle identifiers of the media apps currently playing, empty when the
    /// speakers are idle or the noise comes from something the key cannot reach.
    static func playingApps(ownBundleID: String) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            MediaPlaybackPolicy.controllable(
                AudioOutputActivity.runningOutputBundleIDs(), ownBundleID: ownBundleID)
        }.value
    }
}
