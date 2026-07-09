import Foundation

/// One dictation session's diagnostic record. Pure data: assembled by
/// `DiagnosticsRecorder`, written to disk by `DiagnosticsStore`, read back by a
/// developer (and the eval converter). Local-only — it never leaves the machine
/// and is only ever produced by a `DIAGNOSTICS`-flagged build.
struct SessionTrace: Codable, Equatable {
    var id: String
    var startedAt: Date
    var context: Context
    /// Ordered timeline of stage marks, each in ms since the session began.
    var timeline: [Mark]
    var asr: ASRStats?
    var audio: AudioStats?
    var text: TextChain

    /// The knobs and outcome that frame how to read the numbers.
    struct Context: Codable, Equatable {
        var appVersion: String
        var engine: String
        var fillerFilter: Bool
        var llmCleanup: Bool
        var itn: Bool
        var holdToTalk: Bool
        /// native / web / clipboard / none — how the final text was delivered.
        var pasteOutcome: String?
        /// The app that received the paste (frontmost at delivery time).
        var frontApp: String? = nil
        var frontAppBundleID: String? = nil
        /// When the optional qwen polish ran relative to the paste:
        /// `beforePaste` (web/Electron compute-then-paste), `afterPaste` (native
        /// paste-then-refine in place), or `none` (polish off / no delivery).
        var polishTiming: String? = nil
    }

    /// A single point on the session timeline.
    struct Mark: Codable, Equatable {
        var stage: String
        var msSinceStart: Int
    }

    struct ASRStats: Codable, Equatable {
        var audioDurationMs: Int
        /// processing time / audio duration — <1 is faster than real time.
        var realTimeFactor: Double
        var confirmedChars: Int
        var volatileChars: Int
        var usedSalvagePath: Bool
        var wordCount: Int
    }

    struct AudioStats: Codable, Equatable {
        var inputDeviceName: String
        var isBluetooth: Bool
        var sampleRate: Double
        var channelCount: Int
        var rmsMean: Float
        var peak: Float
        var clippedPct: Float
        var droppedBuffers: Int
    }

    /// Raw ASR text and what each pipeline stage turned it into — a diff across
    /// `stages` shows exactly which pass changed what.
    struct TextChain: Codable, Equatable {
        var rawAsr: String = ""
        var stages: [StageText] = []
        var finalPasted: String = ""

        struct StageText: Codable, Equatable {
            var stage: String
            var text: String
        }
    }

    /// Time spent between consecutive timeline marks, in order. `deltaMs` for the
    /// first mark is measured from session start (0).
    struct StageDelta: Equatable {
        let stage: String
        let deltaMs: Int
    }

    func stageDeltas() -> [StageDelta] {
        var previous = 0
        return timeline.map { mark in
            defer { previous = mark.msSinceStart }
            return StageDelta(stage: mark.stage, deltaMs: mark.msSinceStart - previous)
        }
    }
}

/// Canonical timeline stage names — one source of truth for the marks the
/// recorder emits and the deltas we read back. Raw strings keep the on-disk JSON
/// stable and human-readable.
enum DiagnosticsStage: String {
    case armed              // key-down handled, phase flipped
    case engineStarted      // ASR streaming session up
    case micStarted         // AVAudioEngine capturing
    case firstBuffer        // first mic buffer arrived
    case firstPartial       // first volatile transcript
    case firstConfirmed     // first confirmed transcript
    case stopRequested      // user released the key
    case finalizeStart      // finalize pipeline begins
    case spacing            // TranscriptSpacingRepair done
    case selfCorrection     // SelfCorrectionCollapser done
    case itn                // DeterministicITN done
    case filler             // FillerWordFilter done
    case vocab              // VocabularyPostProcessor done
    case llmPolish          // optional qwen refine done
    case guardChecked       // faithfulness guard verdict
    case pasted             // text delivered
}
