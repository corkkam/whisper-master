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
/// **⚠️ The one rule that everything else here defends: press the key once per
/// hold, and never again.** The play/pause key is a toggle, and a player keeps its
/// Core Audio output stream alive for about 3.5 seconds after it stops — so a
/// press that worked still reads as "audio is playing" for seconds afterwards.
/// The first version re-checked 400 ms after pressing, concluded it had failed,
/// and let the next 0.5 s tick press again: the music went off, on, off, on for as
/// long as the key was held, and whichever phase it landed in is what the user was
/// left with. `pressedForHold` is what makes that impossible.
///
/// The remaining rules:
///
/// - **Only resume what we paused.** `didPause` is cleared the moment the
///   confirmation below shows we pressed the wrong way, so a press that reached
///   nothing never earns a second press later.
/// - **Never resume over something else.** If the user started playing again
///   themselves while we were listening, the release is dropped rather than
///   pausing them a second time.
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

    /// How long to keep watching after the press before deciding it went the wrong
    /// way. **Must stay comfortably above the ~3.5 s output-stream linger**, or a
    /// successful pause is read as a failure. Measured on this machine with a player
    /// paused by hand; the confirmation below wants the stream to go quiet *once*,
    /// which it does within the linger.
    static let confirmWindow: TimeInterval = 6

    /// We have pressed for the current hold. One press in, one press out — no matter
    /// what the speakers appear to be doing in between.
    private var pressedForHold = false
    /// The press is believed to have paused something, so the release owes a press
    /// back. Optimistic at the press, withdrawn if the confirmation disagrees.
    private var didPause = false
    /// The app still wants silence. Read after the off-main Core Audio look, so a
    /// session that ended while we were looking does not get a pointless pause.
    private var wantsHold = false
    private var lastBusyAt: Date?
    /// One Core Audio conversation at a time; the 0.5 s tick would otherwise start a
    /// second one on top of the first.
    private var working = false

    /// The world, injectable so `MediaPauserTests` can drive the press-once rule
    /// without a speaker, a key press, or a six-second wait. The defaults are the
    /// real thing.
    struct Environment {
        var ownBundleID: String = Bundle.main.bundleIdentifier ?? ""
        var playingApps: (String) async -> [String] = {
            await MediaPlaybackState.playingApps(ownBundleID: $0)
        }
        var press: @MainActor (MediaKey.Key) -> Void = { MediaKey.send($0) }
        var confirmInterval: UInt64 = 500_000_000
        var confirmWindow: TimeInterval = MediaPauser.confirmWindow
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
            defer { working = false }
            let playing = await env.playingApps(env.ownBundleID)
            guard wantsHold, !playing.isEmpty else { return }
            pressedForHold = true
            didPause = true
            env.press(.playPause)
            await confirmPause()
        }
    }

    /// Watch until the speakers go quiet, which is what a working pause looks like
    /// once the stream linger has run out. If they never do, the press went the wrong
    /// way — it started something that was sitting paused — so undo it, once.
    ///
    /// This is the whole reason a wrong press costs a few seconds of music instead of
    /// a whole dictation.
    private func confirmPause() async {
        let deadline = Date().addingTimeInterval(env.confirmWindow)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: env.confirmInterval)
            // The hold ended while we watched. `release()` owes the press back, and
            // pressing here as well would cancel it out.
            guard wantsHold, didPause else { return }
            if await env.playingApps(env.ownBundleID).isEmpty {
                return  // Quiet. The pause took.
            }
        }
        // Still playing well past the linger: we started something rather than
        // stopping it. Put it back and remember there is nothing to resume.
        didPause = false
        env.press(.playPause)
    }

    private func release() {
        pressedForHold = false
        guard didPause, !working else {
            didPause = false
            return
        }
        didPause = false
        working = true
        Task { [env] in
            defer { working = false }
            // Something is playing again without us — the user pressed play, or another
            // app started. Pressing now would pause *that*.
            let playing = await env.playingApps(env.ownBundleID)
            if playing.isEmpty { env.press(.playPause) }
        }
    }
}
