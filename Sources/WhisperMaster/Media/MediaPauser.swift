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
/// Three rules keep this from being the kind of "helpful" that ruins an afternoon:
///
/// - **It only presses the key when it can see media playing** (`MediaPlaybackPolicy`),
///   because the key is a toggle and a blind press can start music rather than stop it.
/// - **It only resumes what it paused.** `didPause` is set from what the speakers
///   actually did, not from having sent the key, so a press that reached nothing
///   never earns a second press later.
/// - **It never resumes over something else.** If the user started playing again
///   themselves while we were listening, the resume is dropped rather than pausing
///   them a second time.
@MainActor
final class MediaPauser {
    /// How long everything has to stay quiet before the music comes back. The window
    /// covers the handover gaps inside one exchange — recording ends a beat before the
    /// assistant reports that it is running, and the agent finishes a beat before the
    /// answer starts being spoken — and without it the music would flick on and off
    /// between the stages of a single question.
    static let resumeGrace: TimeInterval = 1.2

    /// How long to wait before believing the key press worked. A player stops its
    /// stream a little after it stops the audio.
    private static let settleNanoseconds: UInt64 = 400_000_000

    /// True when the speakers actually went quiet for us — the only thing that earns
    /// a resume.
    private var didPause = false
    /// The app still wants silence. Read after the off-main Core Audio look, so a
    /// session that ended while we were looking does not get a pointless pause.
    private var wantsHold = false
    private var lastBusyAt: Date?
    /// One Core Audio conversation at a time; the 0.5 s tick would otherwise start a
    /// second one on top of the first.
    private var working = false

    private let ownBundleID = Bundle.main.bundleIdentifier ?? ""

    /// Called from the key press (immediately, `busy: true`) and from the 0.5 s
    /// refresh tick (with whatever the app is doing).
    func update(enabled: Bool, busy: Bool, now: Date = Date()) {
        guard enabled else {
            // Switched off mid-hold: give the music back rather than stranding it.
            wantsHold = false
            resumeIfNeeded()
            return
        }
        if busy {
            wantsHold = true
            lastBusyAt = now
            pauseIfNeeded()
        } else if wantsHold, now.timeIntervalSince(lastBusyAt ?? now) >= Self.resumeGrace {
            wantsHold = false
            resumeIfNeeded()
        }
    }

    /// The app is going away. Nothing else will run the tick, so anything we paused
    /// is released here rather than left paused with no app to explain it.
    func releaseForTermination() {
        guard didPause else { return }
        didPause = false
        wantsHold = false
        MediaKey.sendPlayPause()
    }

    // MARK: - Internals

    private func pauseIfNeeded() {
        guard !didPause, !working else { return }
        working = true
        Task { [ownBundleID] in
            defer { working = false }
            let playing = await Self.runningOutput()
            guard wantsHold,
                  MediaPlaybackPolicy.shouldPause(runningOutput: playing, ownBundleID: ownBundleID)
            else { return }
            MediaKey.sendPlayPause()
            try? await Task.sleep(nanoseconds: Self.settleNanoseconds)
            let after = await Self.runningOutput()
            // Only remember a pause the speakers agreed to. A player that ignored the
            // key leaves this false, so we never press again on its behalf.
            didPause = !MediaPlaybackPolicy.shouldPause(
                runningOutput: after, ownBundleID: ownBundleID)
        }
    }

    private func resumeIfNeeded() {
        guard didPause, !working else { return }
        working = true
        Task { [ownBundleID] in
            defer { working = false }
            let playing = await Self.runningOutput()
            // Something is playing again without us — the user pressed play, or another
            // app started. Pressing now would pause *that*.
            if !MediaPlaybackPolicy.shouldPause(runningOutput: playing, ownBundleID: ownBundleID) {
                MediaKey.sendPlayPause()
            }
            didPause = false
        }
    }

    /// Off the main actor: each property read is an IPC round trip to `coreaudiod`,
    /// and this runs on the same key press that has to start the microphone.
    private static func runningOutput() async -> [String] {
        await Task.detached(priority: .userInitiated) {
            AudioOutputActivity.runningOutputBundleIDs()
        }.value
    }
}
