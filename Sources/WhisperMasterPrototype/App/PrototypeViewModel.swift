import AppKit
@preconcurrency import AVFoundation
import FluidAudio
import Foundation

@MainActor
final class PrototypeViewModel {
    let state: PrototypeAppState

    private let microphoneCapture: MicrophoneCaptureService
    private let permissionsManager: PermissionsManager
    private let hotkeyUpdater: (HotkeyManager.HotkeyOption) -> Void
    private let transcriber: FluidAudioStreamingTranscriber
    private let textInjector: TextInjector
    private var pendingAppendTasks: [UUID: Task<Void, Never>] = [:]
    private var preparationTask: Task<Void, Never>?
    private let releaseTailNanoseconds: UInt64 = 80_000_000

    init(
        state: PrototypeAppState,
        microphoneCapture: MicrophoneCaptureService,
        permissionsManager: PermissionsManager,
        hotkeyUpdater: @escaping (HotkeyManager.HotkeyOption) -> Void = { _ in },
        transcriber: FluidAudioStreamingTranscriber,
        textInjector: TextInjector
    ) {
        self.state = state
        self.microphoneCapture = microphoneCapture
        self.permissionsManager = permissionsManager
        self.hotkeyUpdater = hotkeyUpdater
        self.transcriber = transcriber
        self.textInjector = textInjector
    }

    convenience init() {
        self.init(hotkeyUpdater: { _ in })
    }

    convenience init(
        hotkeyUpdater: @escaping (HotkeyManager.HotkeyOption) -> Void
    ) {
        self.init(
            state: PrototypeAppState(),
            microphoneCapture: MicrophoneCaptureService(),
            permissionsManager: PermissionsManager(),
            hotkeyUpdater: hotkeyUpdater,
            transcriber: FluidAudioStreamingTranscriber(),
            textInjector: TextInjector()
        )
    }

    func startRecording() {
        guard state.canStart else { return }

        state.phase = .preparingModels
        state.audioLevel = 0
        state.resetTranscript()
        state.statusMessage = "Getting voice engine ready..."

        Task {
            do {
                let micAllowed = await microphoneCapture.ensurePermission()
                guard micAllowed else {
                    throw MicrophoneCaptureService.CaptureError.microphoneUnavailable
                }

                try await prepareSelectedEngineIfNeeded()

                // Custom vocabulary: register terms now (cheap) and load the
                // CTC model in the background, so recording starts immediately
                // and biasing kicks in once it's ready — never blocking.
                await transcriber.setVocabulary(state.customVocabulary)
                Task { [transcriber] in await transcriber.loadVocabularyResources() }

                state.download = nil
                state.statusMessage = "Voice engine ready. Starting microphone..."

                try await transcriber.start { [weak self] update in
                    Task { @MainActor in
                        guard let self else { return }
                        self.applyTranscriptUpdate(update)
                        if update.isConfirmed {
                            self.state.statusMessage = "Receiving confirmed local transcript..."
                        } else {
                            self.state.statusMessage = "Receiving live partial transcript..."
                        }
                    }
                }

                try microphoneCapture.start(
                    bufferHandler: { [weak self] buffer in
                        guard let self else { return }
                        Task { @MainActor in
                            self.enqueueAudioBuffer(buffer)
                        }
                    },
                    levelHandler: { [weak self] level in
                        Task { @MainActor in
                            self?.state.audioLevel = level
                        }
                    }
                )

                state.phase = .recording
                state.statusMessage = "Recording with \(state.selectedEngine.displayName)..."
            } catch {
                await handleFailure(error)
            }
        }
    }

    func stopRecording() {
        guard state.canStop else { return }

        state.phase = .stopping
        state.audioLevel = 0
        state.statusMessage = "Catching final words..."

        Task {
            do {
                try? await Task.sleep(nanoseconds: releaseTailNanoseconds)
                microphoneCapture.stop()
                await drainPendingAudioBuffers()
                state.statusMessage = "Finalizing local transcript..."
                let final = try await transcriber.stop()
                state.phase = .idle
                state.transcript.finalText = final
                if !final.isEmpty {
                    state.transcript.latestConfirmed = final
                    state.transcript.latestPartial = ""
                    state.appendHistory(text: final, engine: state.selectedEngine)
                    if state.autoPasteEnabled {
                        await injectFinalTextIfPossible(final)
                    }
                }
                state.statusMessage = "Finished local transcription."
            } catch {
                await handleFailure(error)
            }
        }
    }

    func cancelSession() {
        microphoneCapture.stop()
        Task {
            await transcriber.cancel()
            await MainActor.run {
                self.state.phase = .idle
                self.state.audioLevel = 0
                self.state.statusMessage = "Session cancelled."
            }
        }
    }

    func cancelModelPreparation() {
        preparationTask?.cancel()
        preparationTask = nil

        if let preparingEngine = state.preparingEngine {
            state.preparingEngine = nil
            state.download = nil
            state.statusMessage = "\(preparingEngine.userFacingName) setup cancelled."
        }

        if case .preparingModels = state.phase {
            state.phase = .idle
        }
    }

    func shutdown() {
        preparationTask?.cancel()
        microphoneCapture.stop()
        pendingAppendTasks.values.forEach { $0.cancel() }
        pendingAppendTasks.removeAll()
    }

    private func enqueueAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let id = UUID()
        let task = Task { [transcriber] in
            try? await transcriber.append(buffer)
            return
        }
        pendingAppendTasks[id] = task

        Task { @MainActor in
            await task.value
            pendingAppendTasks[id] = nil
        }
    }

    private func drainPendingAudioBuffers() async {
        let tasks = Array(pendingAppendTasks.values)
        pendingAppendTasks.removeAll()

        for task in tasks {
            await task.value
        }
    }

    func toggleAccessibilityHelp() {
        permissionsManager.promptAccessibility()
        permissionsManager.openAccessibilitySettings()
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func pasteText(_ text: String) {
        copyToClipboard(text)
        guard permissionsManager.accessibilityGranted() else {
            state.statusMessage = "Copied to clipboard. Enable Accessibility for auto-paste."
            return
        }
        Task { [textInjector] in
            await textInjector.inject(text)
        }
    }

    func pasteLastTranscript() {
        guard let entry = state.history.first else { return }
        pasteText(entry.text)
    }

    func deleteHistoryEntry(_ id: UUID) {
        state.removeHistoryEntry(id)
    }

    func clearAllHistory() {
        state.clearHistory()
    }

    func handleHotkeyPressed() {
        guard state.holdToTalkEnabled else { return }
        if state.preparingEngine != nil {
            state.statusMessage = "Voice engine is still getting ready."
            return
        }
        if state.canStart {
            startRecording()
        }
    }

    func handleHotkeyReleased() {
        guard state.holdToTalkEnabled else { return }
        if state.canStop {
            stopRecording()
        }
    }

    func updateHotkey(_ hotkey: HotkeyManager.HotkeyOption) {
        state.hotkey = hotkey
        hotkeyUpdater(hotkey)
    }

    func selectEngine(_ engine: TranscriberEngine) {
        guard state.selectedEngine != engine else { return }
        state.selectedEngine = engine
        state.download = nil
        state.statusMessage = "Getting voice engine ready..."
        prepareSelectedEngineInBackground()
    }

    func prepareDefaultEngineOnLaunch() {
        state.statusMessage = "Getting voice engine ready..."
        prepareSelectedEngineInBackground()
    }

    func prepareSelectedEngineInBackground() {
        let engine = state.selectedEngine
        guard state.preparedEngine != engine, state.preparingEngine != engine else { return }

        // A prior background prep may have left the phase in `.failed`; clear it
        // so the retry starts from a clean state (the recording path never hits
        // this method, so we won't stomp on a `.preparingModels`/`.recording` phase).
        if case .failed = state.phase {
            state.phase = .idle
        }

        preparationTask?.cancel()
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareEngine(engine)
            } catch {
                guard !Task.isCancelled else { return }
                await self.handlePreparationFailure(error, engine: engine)
            }
        }
    }

    private func handleFailure(_ error: Error) async {
        microphoneCapture.stop()
        await transcriber.cancel()
        await MainActor.run {
            self.state.phase = .failed(error.localizedDescription)
            self.state.audioLevel = 0
            self.state.statusMessage = "Prototype failed: \(error.localizedDescription)"
        }
    }

    private func handlePreparationFailure(_ error: Error, engine: TranscriberEngine) async {
        await MainActor.run {
            if self.state.preparingEngine == engine {
                self.state.preparingEngine = nil
                self.state.download = nil
            }
            self.state.phase = .failed(error.localizedDescription)
            self.state.statusMessage = "Couldn't get the voice engine ready. Check your connection and try again."
        }
    }

    private static func detailText(for snapshot: DownloadUtils.DownloadProgress) -> String {
        switch snapshot.phase {
        case .listing:
            return "Checking voice engine..."
        case .downloading(let completedFiles, let totalFiles):
            if totalFiles > 0 {
                return "Downloading voice engine (\(completedFiles)/\(totalFiles))..."
            }
            return "Downloading voice engine..."
        case .compiling:
            return "Optimizing voice engine..."
        }
    }

    private func prepareSelectedEngineIfNeeded() async throws {
        let engine = state.selectedEngine
        if state.preparedEngine == engine { return }
        try await prepareEngine(engine)
    }

    private func prepareEngine(_ engine: TranscriberEngine) async throws {
        if state.preparedEngine == engine { return }

        state.preparingEngine = engine
        state.download = nil
        state.statusMessage = engine.isInstalled
            ? "Loading voice engine..."
            : "Downloading voice engine..."

        await installModelsFromMirror(engine)
        try await transcriber.prepareModels { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.state.preparingEngine == engine else { return }
                let detail = Self.detailText(for: snapshot)
                self.state.download = ModelDownloadSnapshot(
                    fractionCompleted: snapshot.fractionCompleted,
                    detail: detail
                )
                self.state.statusMessage = detail
            }
        }

        guard !Task.isCancelled else { return }
        state.preparedEngine = engine
        state.preparingEngine = nil
        state.download = nil
        state.statusMessage = "Voice engine ready."
    }

    /// Prefer the fast R2 model mirror (accurate %, free egress); on any
    /// failure fall through so FluidAudio downloads from HuggingFace as before.
    private func installModelsFromMirror(_ engine: TranscriberEngine) async {
        do {
            try await ModelInstaller.installIfNeeded(engine) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.state.preparingEngine == engine else { return }
                    self.state.download = ModelDownloadSnapshot(
                        fractionCompleted: progress.fractionCompleted,
                        detail: progress.detail
                    )
                    self.state.statusMessage = progress.detail
                }
            }
        } catch {
            NSLog("Model mirror install failed for %@; using HuggingFace fallback: %@",
                  engine.displayName, String(describing: error))
        }
    }

    private func applyTranscriptUpdate(_ update: StreamingTranscriptUpdate) {
        if update.isConfirmed, !update.confirmedText.isEmpty {
            state.transcript.latestConfirmed = mergedConfirmedTranscript(
                currentConfirmed: state.transcript.latestConfirmed,
                newConfirmed: update.confirmedText
            )
        }

        let latestSource = !update.latestText.isEmpty ? update.latestText : update.partialText
        state.transcript.latestPartial = partialRemainder(
            partialText: latestSource,
            confirmedText: state.transcript.latestConfirmed
        )
    }

    private func mergedConfirmedTranscript(
        currentConfirmed: String,
        newConfirmed: String
    ) -> String {
        let current = normalizedSpaces(in: currentConfirmed)
        let incoming = normalizedSpaces(in: newConfirmed)

        if current.isEmpty { return incoming }
        if incoming.isEmpty { return current }
        if incoming.hasPrefix(current) { return incoming }
        if current.hasPrefix(incoming) { return current }

        let overlap = longestSuffixPrefixOverlap(lhs: current, rhs: incoming)
        if overlap > 0 {
            let suffixStart = incoming.index(incoming.startIndex, offsetBy: overlap)
            let suffix = incoming[suffixStart...]
            return normalizedSpaces(in: current + " " + suffix)
        }

        return normalizedSpaces(in: current + " " + incoming)
    }

    private func partialRemainder(partialText: String, confirmedText: String) -> String {
        let partial = normalizedSpaces(in: partialText)
        let confirmed = normalizedSpaces(in: confirmedText)

        guard !partial.isEmpty else { return "" }
        guard !confirmed.isEmpty else { return partial }

        if partial.hasPrefix(confirmed) {
            let start = partial.index(partial.startIndex, offsetBy: confirmed.count)
            return normalizedSpaces(in: String(partial[start...]))
        }

        return partial
    }

    private func normalizedSpaces(in text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func longestSuffixPrefixOverlap(lhs: String, rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        let maxOverlap = min(lhsChars.count, rhsChars.count)

        guard maxOverlap > 0 else { return 0 }

        for length in stride(from: maxOverlap, through: 1, by: -1) {
            let lhsSuffix = lhsChars.suffix(length)
            let rhsPrefix = rhsChars.prefix(length)
            if lhsSuffix.elementsEqual(rhsPrefix) {
                return length
            }
        }

        return 0
    }

    private func injectFinalTextIfPossible(_ text: String) async {
        guard permissionsManager.accessibilityGranted() else {
            await MainActor.run {
                self.state.statusMessage = "Transcript ready. Enable Accessibility for auto-paste."
            }
            return
        }

        await textInjector.inject(text)
        await MainActor.run {
            self.state.statusMessage = "Finished local transcription and pasted at cursor."
        }
    }
}
