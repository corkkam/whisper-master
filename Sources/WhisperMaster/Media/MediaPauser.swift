import Foundation

/// Holds the user's music while the app is listening or talking, and gives it back
/// afterwards.
///
/// Dictating over a podcast means transcribing the podcast: the mic hears the
/// speakers, and the words that come back are a blend of two people. So the moment
/// the push-to-talk key goes down — or the assistant chord, or the agent key — the
/// media playing on this Mac is paused, and it resumes once the whole exchange is
/// over, including the answer being read aloud.
///
/// **⚠️ Exactly two key presses leave this class per hold: one down, one up. Nothing
/// presses in between, and nothing may be added that does.** The play/pause key is a
/// toggle, and the only signal we have for "is media playing" is whether a process is
/// running a Core Audio output stream — which stays true for seconds after playback
/// actually stops, and for a browser longer still. So a mid-hold press is always
/// acting on a guess, and a wrong guess here is not quiet: it starts the user's music
/// in the middle of the sentence they are dictating.
///
/// Two shipped bugs, both of them a mid-hold press:
///
/// 1. The first version pressed, re-checked 400 ms later, saw the stream still alive,
///    concluded the press had failed, and pressed again on the next tick — off, on,
///    off, on for as long as the key was held.
/// 2. The second version pressed once and then watched for up to six seconds for the
///    speakers to go quiet, pressing back if they never did. A browser holds its
///    output stream open longer than that window, so on a machine playing YouTube the
///    pause was *correct* and then undone a few seconds into every dictation. The
///    music came back mid-sentence and was never handed over again, because the
///    press-back had cleared the debt.
///
/// What replaced it is not a better watcher, it is no watcher. A press that went the
/// wrong way — the stream we saw was the tail of playback the user had already paused
/// by hand, so the press *started* the music — is corrected by the release press,
/// which has to happen anyway and needs no inference to be right. The user's media
/// therefore always ends the exchange in the state they left it in; the only cost of a
/// wrong guess is that it plays for the length of the dictation, instead of being
/// silenced at a moment we picked by reading tea leaves.
///
/// The two remaining rules:
///
/// - **Only press when a recognised player is running output** — `MediaPlaybackPolicy`
///   is an allowlist, because the key is a toggle and pressing it at silence starts
///   whatever was paused.
/// - **A spoken "play" or "pause" takes the wheel** (`yieldToUser`): after the user
///   says it, this stops having an opinion for the rest of the hold.
@MainActor
final class MediaPauser {
    /// How long everything has to stay quiet before the music comes back. The window
    /// covers the handover gaps inside one exchange — recording ends a beat before the
    /// assistant reports that it is running, and the agent finishes a beat before the
    /// answer starts being spoken — and without it the music would flick on and off
    /// between the stages of a single question.
    static let resumeGrace: TimeInterval = 1.2

    /// We have pressed for the current hold. One press in, one press out — no matter
    /// what the speakers appear to be doing in between.
    private var pressedForHold = false
    /// The press is owed back at release. Set at the press and cleared only by the
    /// release itself or by the user taking the wheel — never by anything that has
    /// looked at the speakers and drawn a conclusion.
    private var didPause = false
    /// The app still wants silence. Read after the off-main Core Audio look, so a
    /// session that ended while we were looking does not get a pointless pause.
    private var wantsHold = false
    private var lastBusyAt: Date?
    /// A Core Audio look is in flight; the 0.5 s tick would otherwise start a second
    /// one on top of the first. It is raised for that one read and lowered again as
    /// soon as it returns — never held across a wait, which is how a release once
    /// found the pauser busy and dropped the press that hands the music back.
    private var working = false

    /// The world, injectable so `MediaPauserTests` can drive the press-once rule
    /// without a speaker and without a key press. The defaults are the real thing.
    struct Environment {
        var ownBundleID: String = Bundle.main.bundleIdentifier ?? ""
        var playingApps: (String) async -> [String] = {
            await MediaPlaybackState.playingApps(ownBundleID: $0)
        }
        var press: @MainActor (MediaKey.Key) -> Void = { MediaKey.send($0) }
    }

    private let env: Environment

    init(environment: Environment = Environment()) {
        self.env = environment
    }

    private var ownBundleID: String { env.ownBundleID }

    /// Called from the key press (immediately, `busy: true`) and from the 0.5 s
    /// refresh tick (with whatever the app is doing).
    func update(enabled: Bool, busy: Bool, now: Date = Date()) {
        guard enabled else {
            // Switched off mid-hold: give the music back rather than stranding it.
            wantsHold = false
            release()
            return
        }
        if busy {
            wantsHold = true
            lastBusyAt = now
            pauseIfNeeded()
        } else if wantsHold, now.timeIntervalSince(lastBusyAt ?? now) >= Self.resumeGrace {
            wantsHold = false
            release()
        }
    }

    /// The user just said "play" or "pause" out loud. Their instruction outranks the
    /// automatic hold, so we stop having an opinion until the next dictation: no
    /// press to pause, and no press to resume.
    ///
    /// - Returns: whether we were holding a pause at that moment. A spoken "pause"
    ///   usually lands on music this app silenced a second earlier when the chord went
    ///   down, and the answer would otherwise read "it was already paused" — true, but
    ///   only because of something the user never saw happen.
    @discardableResult
    func yieldToUser() -> Bool {
        let wasHolding = didPause
        pressedForHold = true
        didPause = false
        return wasHolding
    }

    /// The app is going away. Nothing else will run the tick, so anything we paused
    /// is released here rather than left paused with no app to explain it.
    func releaseForTermination() {
        guard didPause else { return }
        didPause = false
        pressedForHold = false
        wantsHold = false
        env.press(.playPause)
    }

    // MARK: - Internals

    private func pauseIfNeeded() {
        guard !pressedForHold, !working else { return }
        working = true
        Task { [env] in
            let playing = await env.playingApps(env.ownBundleID)
            working = false
            // Re-read after the await: the hold can have ended, or another look can
            // have pressed already, while this one was in flight.
            guard wantsHold, !pressedForHold, !playing.isEmpty else { return }
            pressedForHold = true
            didPause = true
            env.press(.playPause)
        }
    }

    /// The press out, and it asks nobody's permission.
    ///
    /// **⚠️ It deliberately does not look at the speakers first.** A Core Audio read
    /// here cannot tell three things apart: the player we paused a second ago, still
    /// lingering; a courtesy stream another app opened because *we* were reading the
    /// answer aloud (a browser does this whenever anything else plays); and the user
    /// starting something themselves. Guarding on "is anything playing" swallowed the
    /// resume after every short exchange, and left the Mac silent with no explanation.
    ///
    /// It is also the correction for a press that went the wrong way. If the stream we
    /// saw at the key press was the tail of playback the user had already stopped, the
    /// press started their music — and this press stops it again. Either way the media
    /// ends the exchange in the state the user left it in, which is why nothing in
    /// between needs to work out which of the two happened.
    private func release() {
        pressedForHold = false
        guard didPause else { return }
        didPause = false
        env.press(.playPause)
    }
}
