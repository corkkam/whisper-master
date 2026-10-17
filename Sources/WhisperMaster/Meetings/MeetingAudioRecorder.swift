@preconcurrency import AVFoundation
import Foundation

/// Writes a meeting's two tracks to disk as they arrive, and mixes them into the
/// one `.m4a` the note plays back.
///
/// **Streamed to disk, not held in memory.** `SessionAudioWriter` keeps a
/// dictation in memory and stops at 5 min; a meeting runs an hour, which is
/// ~230 MB of Float32 per track. Each track goes to its own temporary CAF at
/// 16 kHz mono, and `finish` mixes them into a small AAC file beside the other
/// note recordings (`NoteAudioStore.directory`), then deletes the CAFs.
///
/// **This is the one place the app writes meeting audio to disk, on purpose.**
/// The user pressed "Take notes", and a recording kept beside the notes is what
/// they asked for. It never leaves the Mac: `NotesSyncClient` does not sync audio.
final class MeetingAudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = Date()
    private var tracks: [MeetingSpeaker: Track] = [:]
    /// Set by `finish` and `cancel`. A buffer still in flight after that is
    /// dropped instead of opening a new track in a folder that is already gone.
    private var isClosed = false
    private let directory: URL

    /// Every recording's temporary folder starts with this (`removeLeftovers`).
    static let directoryPrefix = "WhisperMasterMeeting-"

    private final class Track {
        let url: URL
        let file: AVAudioFile
        init(url: URL, file: AVAudioFile) {
            self.url = url
            self.file = file
        }
    }

    init(directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(directoryPrefix)\(UUID().uuidString)", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Append a 16 kHz mono buffer (`MonoResampler.format`) to one track. The
    /// first buffer of a track is preceded by silence for the time since the
    /// meeting started, so the two tracks line up when mixed.
    func append(_ buffer: AVAudioPCMBuffer, speaker: MeetingSpeaker) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        do {
            let track: Track
            if let existing = tracks[speaker] {
                track = existing
            } else {
                let url = directory.appendingPathComponent("\(speaker.rawValue).caf")
                let file = try AVAudioFile(
                    forWriting: url, settings: MonoResampler.format.settings,
                    commonFormat: .pcmFormatFloat32, interleaved: false)
                track = Track(url: url, file: file)
                tracks[speaker] = track
                let lead = AVAudioFrameCount(Date().timeIntervalSince(startedAt) * MonoResampler.sampleRate)
                if lead > 0, let silence = AVAudioPCMBuffer(pcmFormat: MonoResampler.format, frameCapacity: lead) {
                    silence.frameLength = lead
                    if let data = silence.floatChannelData { memset(data[0], 0, Int(lead) * 4) }
                    try file.write(from: silence)
                }
            }
            try track.file.write(from: buffer)
        } catch {
            Log.notes.error("meeting audio write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Mix both tracks into `<noteID>.m4a` in the note audio directory. Returns
    /// the `NoteAudio` to store on the note, or nil when nothing was recorded or
    /// the mix failed. The temporary tracks are deleted either way.
    func finish(noteID: UUID) -> NoteAudio? {
        lock.lock()
        isClosed = true
        let urls = tracks.values.map(\.url)
        tracks.removeAll()  // closes the files
        lock.unlock()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard !urls.isEmpty else { return nil }

        let fileName = "\(noteID.uuidString).m4a"
        let output = NoteAudioStore.url(for: fileName)
        do {
            try FileManager.default.createDirectory(
                at: NoteAudioStore.directory, withIntermediateDirectories: true)
            let frames = try Self.mix(urls, to: output)
            guard frames > 0 else { return nil }
            return NoteAudio(fileName: fileName, durationMs: Int(Double(frames) / MonoResampler.sampleRate * 1000))
        } catch {
            Log.notes.error("meeting audio mix failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: output)
            return nil
        }
    }

    /// Discard everything without producing a file.
    func cancel() {
        lock.lock()
        isClosed = true
        tracks.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Delete the folders a quit or a crash left behind. A meeting that ends
    /// normally deletes its own; one interrupted mid-call leaves both sides of the
    /// conversation, ~460 MB an hour, where nothing would ever remove it. A folder
    /// written to within `staleAfter` is left alone, in case another copy of the
    /// app is recording into it right now.
    static func removeLeftovers(in parent: URL = FileManager.default.temporaryDirectory,
                                staleAfter: TimeInterval = 600, now: Date = Date()) {
        let fileManager = FileManager.default
        let key = URLResourceKey.contentModificationDateKey
        guard let entries = try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [key])
        else { return }
        for folder in entries where folder.lastPathComponent.hasPrefix(directoryPrefix) {
            let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [key])) ?? []
            let lastWrite = (files + [folder])
                .compactMap { try? $0.resourceValues(forKeys: [key]).contentModificationDate }
                .max() ?? .distantPast
            guard now.timeIntervalSince(lastWrite) > staleAfter else { continue }
            try? fileManager.removeItem(at: folder)
        }
    }

    /// Sum the tracks sample by sample, in 1 s blocks, into an AAC file. Returns
    /// the frame count written.
    static func mix(_ inputs: [URL], to output: URL) throws -> AVAudioFramePosition {
        let readers = try inputs.map { try AVAudioFile(forReading: $0, commonFormat: .pcmFormatFloat32, interleaved: false) }
        let length = readers.map(\.length).max() ?? 0
        guard length > 0 else { return 0 }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: MonoResampler.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let writer = try AVAudioFile(forWriting: output, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let block: AVAudioFrameCount = 16_000
        guard let mixed = AVAudioPCMBuffer(pcmFormat: MonoResampler.format, frameCapacity: block),
              let scratch = AVAudioPCMBuffer(pcmFormat: MonoResampler.format, frameCapacity: block)
        else { return 0 }
        var written: AVAudioFramePosition = 0
        while written < length {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(block), length - written))
            mixed.frameLength = count
            let out = mixed.floatChannelData![0]
            memset(out, 0, Int(count) * 4)
            for reader in readers where reader.framePosition < reader.length {
                scratch.frameLength = 0
                try reader.read(into: scratch, frameCount: count)
                let input = scratch.floatChannelData![0]
                for i in 0..<Int(scratch.frameLength) { out[i] += input[i] }
            }
            for i in 0..<Int(count) { out[i] = max(-1, min(1, out[i])) }
            try writer.write(from: mixed)
            written += AVAudioFramePosition(count)
        }
        return written
    }
}
