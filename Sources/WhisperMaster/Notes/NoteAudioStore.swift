import AVFoundation
import Foundation
import Observation

/// Where the recordings behind spoken notes live on disk.
///
/// Separate from the notes JSON on purpose: a WAV is orders of magnitude bigger
/// than the note it belongs to, and `NotesStore` rewrites its whole snapshot on
/// every keystroke-level mutation. Audio is written once and never rewritten, so
/// it gets its own directory and the note carries only a file name.
///
/// **Not synced.** `NotesSyncClient` pushes the note rows; the audio stays on the
/// Mac that recorded it, which is the same posture as the rest of the app — the
/// transcript leaves (it's text the user chose to store), the voice does not. A
/// note pulled from another Mac therefore has an `audio` field naming a file that
/// isn't here, which `hasLocalAudio` answers honestly rather than presenting a
/// play button that would do nothing.
enum NoteAudioStore {
    /// `…/Application Support/WhisperMaster/Notes/Audio/`.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WhisperMaster/Notes/Audio", isDirectory: true)
    }

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// The on-disk URL for a note's recording, or nil when there's nothing playable
    /// — no audio field, or a file this Mac doesn't have (a synced note).
    static func playableURL(for note: Note) -> URL? {
        guard let audio = note.audio else { return nil }
        let url = self.url(for: audio.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Write a WAV for `noteID` and return the `NoteAudio` to store on the note, or
    /// nil if it couldn't be written. Failure is never fatal: the note still saves,
    /// it just has no recording — the same "the optional thing can only help"
    /// posture as the cleanup model.
    static func save(wav: Data, durationMs: Int, for noteID: UUID) -> NoteAudio? {
        let fileName = "\(noteID.uuidString).wav"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try wav.write(to: url(for: fileName), options: .atomic)
            return NoteAudio(fileName: fileName, durationMs: durationMs)
        } catch {
            Log.notes.error("note audio write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Delete a note's recording. Called from the store's delete path — a
    /// soft-deleted note keeps its row as a sync tombstone, but there's no reason to
    /// keep megabytes of audio for a note the user threw away.
    static func delete(_ audio: NoteAudio?) {
        guard let audio else { return }
        try? FileManager.default.removeItem(at: url(for: audio.fileName))
    }
}

/// Plays back the recording behind a note — one at a time, app-wide.
///
/// **This is playback, not capture**, and it must stay that way: it touches only
/// `AVAudioPlayer` on a finished file. Nothing here goes near `AVAudioEngine` or a
/// Core Audio HAL property, which is what makes it safe to run beside
/// `MicrophoneCaptureService` (see the device-juggling prohibitions in the root
/// `CLAUDE.md`). Same reasoning that keeps `Speech/` separate from `Audio/`.
///
/// One player for the whole app, so starting a second note's audio stops the first
/// — two voices talking over each other is never what the user asked for.
@MainActor
@Observable
final class NoteAudioPlayer {
    /// The note currently sounding, so exactly one card can render as playing.
    private(set) var playingNoteID: UUID?

    private var player: AVAudioPlayer?
    /// Retained so the player isn't collected mid-playback, and so we can tell
    /// *our* completion from a stop we initiated.
    private var delegate: PlaybackDelegate?

    func isPlaying(_ noteID: UUID) -> Bool { playingNoteID == noteID }

    /// Start (or restart) a note's recording. A second call for the note that's
    /// already sounding stops it, so the same button is play and pause.
    func toggle(_ note: Note) {
        if playingNoteID == note.id {
            stop()
            return
        }
        guard let url = NoteAudioStore.playableURL(for: note) else { return }
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let delegate = PlaybackDelegate { [weak self] in
                // Hop to the main actor: AVAudioPlayer calls its delegate on an
                // arbitrary queue, and `playingNoteID` drives SwiftUI.
                Task { @MainActor in self?.finished(note.id) }
            }
            player.delegate = delegate
            self.delegate = delegate
            self.player = player
            player.play()
            playingNoteID = note.id
        } catch {
            Log.notes.error("note audio playback failed: \(error.localizedDescription, privacy: .public)")
            playingNoteID = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        delegate = nil
        playingNoteID = nil
    }

    /// Only clear the flag if the note that finished is still the one we think is
    /// playing — a stop followed immediately by a new play would otherwise let the
    /// old player's completion callback blank out the new one.
    private func finished(_ noteID: UUID) {
        guard playingNoteID == noteID else { return }
        stop()
    }

    private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            onFinish()
        }
    }
}
