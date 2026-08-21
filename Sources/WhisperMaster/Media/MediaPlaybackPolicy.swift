import Foundation

/// Which of the apps currently making noise are worth pressing play/pause for.
///
/// The decision is pure and lives apart from both the Core Audio read that
/// supplies the bundle identifiers (`AudioOutputActivity`) and the key press that
/// acts on it (`MediaKey`), because it is the only part of this feature that can
/// be wrong in a way a user notices — and the only part that can be tested without
/// a speaker.
///
/// **It is an allowlist, and that is the whole safety argument.** The play/pause
/// key is a *toggle* sent to whichever app macOS considers "now playing", so
/// pressing it while the noise comes from something that does not answer media
/// keys — a conference call, a game, a system alert — would not pause that noise
/// and could instead *start* a paused music app. So we press it only when the
/// audio is coming from something we know the key controls. Anything unrecognised
/// is left alone: the cost of missing a pause is a second of background music, and
/// the cost of a wrong press is music suddenly playing over a meeting.
enum MediaPlaybackPolicy {
    /// Bundle-identifier prefixes for apps that both play media and honour the
    /// play/pause key. Prefixes, not exact matches, because the process that
    /// actually holds the output stream is usually a helper: a YouTube tab reports
    /// `com.google.Chrome.helper`, not `com.google.Chrome`.
    static let mediaAppPrefixes: [String] = [
        // Apple
        "com.apple.Music",
        "com.apple.iTunes",
        "com.apple.podcasts",
        "com.apple.TV",
        "com.apple.QuickTimePlayerX",
        "com.apple.Safari",
        // Every WKWebView-hosted player (Safari included) hands its audio to one
        // shared GPU process, so this is what a paused Safari tab looks like.
        "com.apple.WebKit.GPU",
        // Browsers
        "com.google.Chrome",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "ai.perplexity.comet",
        // Dedicated players
        "com.spotify.client",
        "org.videolan.vlc",
        "com.colliderli.iina",
        "com.tidal.desktop",
        "com.deezer.deezer-desktop",
        "tv.plex.desktop",
        "com.soundcloud",
        "com.apple.MobileSMS.MediaPlayback",
    ]

    /// True when at least one app that answers the media key is playing.
    ///
    /// - Parameters:
    ///   - runningOutput: bundle identifiers currently sending audio to the output
    ///     device. Command-line tools and helper processes with no bundle report an
    ///     empty string; those are ignored rather than guessed at.
    ///   - ownBundleID: this app. Reading an answer aloud is our own voice and must
    ///     never look like something to pause.
    static func shouldPause(runningOutput: [String], ownBundleID: String) -> Bool {
        !controllable(runningOutput, ownBundleID: ownBundleID).isEmpty
    }

    /// The subset of `runningOutput` the media key is expected to reach.
    static func controllable(_ runningOutput: [String], ownBundleID: String) -> [String] {
        runningOutput.filter { bundleID in
            guard !bundleID.isEmpty else { return false }
            guard !isOurs(bundleID, ownBundleID: ownBundleID) else { return false }
            return mediaAppPrefixes.contains { bundleID.hasPrefix($0) }
        }
    }

    /// Our own bundle and anything it spawns. Matched by prefix so the beta and dev
    /// channels (`…mac.beta`, `…mac.dev`) are covered by the one identifier the
    /// running build reports.
    private static func isOurs(_ bundleID: String, ownBundleID: String) -> Bool {
        guard !ownBundleID.isEmpty else { return false }
        return bundleID.hasPrefix(ownBundleID)
    }
}
