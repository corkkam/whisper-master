import Foundation

/// Puts the natural voice's models on disk, R2 mirror first.
///
/// FluidAudio can fetch these itself, but only from HuggingFace — and a silent HF
/// fallback is exactly the failure this project already got bitten by once (see the
/// mirror-first rules in the root `CLAUDE.md`). So the archives are published to the
/// same R2 bucket as every other model and pulled with the same generic
/// `ModelInstaller.installIfNeeded`, which brings resumable background downloads,
/// retries, bounded timeouts and an honest percentage along with it.
///
/// ## ⚠️ Where the files must land
///
/// `~/.cache/fluidaudio/Models/`, **not** the app's `Application Support/FluidAudio/
/// Models/` root that the ASR models use. `KokoroAneManager.initialize()` resolves the
/// shared G2P assets through the `G2PModel.shared` singleton, which hardcodes the cache
/// path — FluidAudio's own source warns that honouring a custom directory there
/// downloads to somewhere `G2PModel` can't see and then fails with an opaque
/// `vocabLoadFailed`. Landing both archives where FluidAudio already looks means it
/// finds everything present and never reaches for HuggingFace at all.
///
/// ## Publishing the archives
///
/// Same recipe as the other models (root `CLAUDE.md`). From
/// `~/.cache/fluidaudio/Models`, with `kokoro-82m-coreml/` pruned to just its `ANE/`
/// subdirectory (the mono and Mandarin variants are dead weight we never load):
///
/// ```bash
/// ditto -c -k --keepParent kokoro-82m-coreml kokoro-82m-coreml.zip
/// ditto -c -k --keepParent kokoro           kokoro.zip
/// # upload both to whisper-master/models/ on R2
/// ```
///
/// Do the pull with every voice pack present (they're ~0.5 MB each) so the archive
/// carries them all. Otherwise switching voice in Settings triggers FluidAudio's own
/// per-voice HuggingFace fetch, which is the one path this whole type exists to avoid.
enum NaturalVoiceInstaller {

    /// The 7-stage CoreML chain plus its vocab and default voice pack.
    private static let chainArchive = "kokoro-82m-coreml"
    /// The shared English text→IPA assets, pinned to their own directory by FluidAudio.
    private static let g2pArchive = "kokoro"

    /// The chain is by far the larger download; splitting the bar this way keeps it from
    /// stalling at 99% while the small archive lands.
    private static let chainShareOfProgress = 0.85

    // MARK: - Paths

    /// `~/.cache/fluidaudio/Models` — FluidAudio's own TTS cache root.
    static var modelsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models", isDirectory: true)
    }

    private static var chainDirectory: URL {
        modelsRoot.appendingPathComponent("kokoro-82m-coreml/ANE", isDirectory: true)
    }

    private static var g2pDirectory: URL {
        modelsRoot.appendingPathComponent("kokoro", isDirectory: true)
    }

    /// The 7 `.mlmodelc` bundles, the vocab, and the default voice pack — mirroring
    /// `ModelNames.KokoroAne.requiredModels`, which is what FluidAudio itself checks.
    private static let chainFiles = [
        "KokoroAlbert.mlmodelc", "KokoroPostAlbert.mlmodelc", "KokoroAlignment.mlmodelc",
        "KokoroProsody.mlmodelc", "KokoroNoise.mlmodelc", "KokoroVocoder.mlmodelc",
        "KokoroTail.mlmodelc", "vocab.json", "af_heart.bin"
    ]

    /// `ModelNames.G2P.requiredModels`.
    private static let g2pFiles = ["G2PEncoder.mlmodelc", "G2PDecoder.mlmodelc", "g2p_vocab.json"]

    // MARK: - State

    /// Both halves present. Checked against the **actual files**, not just the folder,
    /// for the same reason `TranscriberEngine.isInstalled` does: a half-deleted install
    /// that masquerades as ready silently drops us to the slow path.
    static var isInstalled: Bool {
        exists(chainFiles, in: chainDirectory) && exists(g2pFiles, in: g2pDirectory)
    }

    private static func exists(_ names: [String], in directory: URL) -> Bool {
        names.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// A voice pack other than the bundled default. These are ~0.5 MB each and
    /// FluidAudio fetches a missing one on demand, so they're not part of `isInstalled`.
    static func voicePackInstalled(_ voice: String) -> Bool {
        FileManager.default.fileExists(
            atPath: chainDirectory.appendingPathComponent("\(voice).bin").path)
    }

    // MARK: - Install

    /// Downloads whatever is missing. Throws if the mirror can't provide it — the caller
    /// keeps using the system voice, which is why there's no HuggingFace fallback here:
    /// silence is not on the table, so a failed download is just "stay on the system
    /// voice and say so in Settings".
    static func install(onProgress: @escaping @Sendable (ModelInstaller.Progress) -> Void) async throws {
        let share = chainShareOfProgress
        try await ModelInstaller.installIfNeeded(
            archiveName: chainArchive,
            destinationRoot: modelsRoot,
            label: "natural voice",
            isInstalled: { exists(chainFiles, in: chainDirectory) },
            onProgress: { progress in
                onProgress(ModelInstaller.Progress(
                    fractionCompleted: progress.fractionCompleted * share,
                    detail: progress.detail))
            })

        try await ModelInstaller.installIfNeeded(
            archiveName: g2pArchive,
            destinationRoot: modelsRoot,
            label: "voice pronunciation data",
            isInstalled: { exists(g2pFiles, in: g2pDirectory) },
            onProgress: { progress in
                onProgress(ModelInstaller.Progress(
                    fractionCompleted: share + progress.fractionCompleted * (1 - share),
                    detail: progress.detail))
            })

        guard isInstalled else { throw ModelInstaller.InstallError.incompleteAfterUnpack }
    }
}

/// The natural voices worth offering, with names a person can choose between.
///
/// Kokoro ships around thirty English voice packs whose ids (`af_heart`, `bm_lewis`)
/// encode accent and gender but tell a user nothing. This is a curated subset with
/// readable labels — the full list is mostly near-duplicates, and a picker with thirty
/// coded ids in it is the same mistake as an unfiltered system-voice list.
enum NaturalVoiceCatalog {

    struct Choice: Identifiable, Hashable {
        /// The Kokoro voice pack id, e.g. `af_heart`.
        let id: String
        let name: String
        let accent: String

        var label: String { "\(name) · \(accent)" }
    }

    /// `af_heart` is FluidAudio's own recommended default (`TtsConstants.recommendedVoice`)
    /// and the one pack guaranteed to be in the bundle.
    static let defaultVoice = "af_heart"

    static let all: [Choice] = [
        Choice(id: "af_heart", name: "Heart", accent: "American"),
        Choice(id: "af_bella", name: "Bella", accent: "American"),
        Choice(id: "af_nicole", name: "Nicole", accent: "American"),
        Choice(id: "af_sarah", name: "Sarah", accent: "American"),
        Choice(id: "am_adam", name: "Adam", accent: "American"),
        Choice(id: "am_michael", name: "Michael", accent: "American"),
        Choice(id: "am_puck", name: "Puck", accent: "American"),
        Choice(id: "bf_emma", name: "Emma", accent: "British"),
        Choice(id: "bf_isabella", name: "Isabella", accent: "British"),
        Choice(id: "bm_george", name: "George", accent: "British"),
        Choice(id: "bm_lewis", name: "Lewis", accent: "British")
    ]

    /// Falls back to the default for an id that isn't offered any more, so a stale
    /// preference can't leave the picker showing nothing.
    static func label(for id: String) -> String {
        all.first { $0.id == id }?.label ?? all.first { $0.id == defaultVoice }?.label ?? id
    }
}
