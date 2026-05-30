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
    private let slidingWindowTranscriber: FluidAudioStreamingTranscriber
    private let eouTranscriber: FluidAudioEouStreamingTranscriber
    private let textInjector: TextInjector
    private let notesService: NotesService
    private let remindersService: RemindersService
    private let intentClassifier: IntentClassifier
    private var pendingAppendTasks: [UUID: Task<Void, Never>] = [:]
    private var preparationTask: Task<Void, Never>?
    private let releaseTailNanoseconds: UInt64 = 80_000_000

    init(
        state: PrototypeAppState,
        microphoneCapture: MicrophoneCaptureService,
        permissionsManager: PermissionsManager,
        hotkeyUpdater: @escaping (HotkeyManager.HotkeyOption) -> Void = { _ in },
        slidingWindowTranscriber: FluidAudioStreamingTranscriber,
        eouTranscriber: FluidAudioEouStreamingTranscriber,
        textInjector: TextInjector,
        notesService: NotesService,
        remindersService: RemindersService,
        intentClassifier: IntentClassifier
    ) {
        self.state = state
        self.microphoneCapture = microphoneCapture
        self.permissionsManager = permissionsManager
        self.hotkeyUpdater = hotkeyUpdater
        self.slidingWindowTranscriber = slidingWindowTranscriber
        self.eouTranscriber = eouTranscriber
        self.textInjector = textInjector
        self.notesService = notesService
        self.remindersService = remindersService
        self.intentClassifier = intentClassifier
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
            slidingWindowTranscriber: FluidAudioStreamingTranscriber(),
            eouTranscriber: FluidAudioEouStreamingTranscriber(),
            textInjector: TextInjector(),
            notesService: NotesService(),
            remindersService: RemindersService(),
            intentClassifier: IntentClassifier()
        )
    }

    private var transcriber: any LocalStreamingTranscriber {
        switch state.selectedEngine {
        case .eouStreaming:
            return eouTranscriber
        case .slidingWindow:
            return slidingWindowTranscriber
        }
    }

    func startRecording() {
        guard state.canStart else { return }

        state.phase = .preparingModels
        state.audioLevel = 0
        state.resetTranscript()
        state.statusMessage = "Getting voice engine ready..."
        state.log("Recording started — mode: \(state.outputMode.shortName)", level: .info, category: .recording)

        Task {
            do {
                let micAllowed = await microphoneCapture.ensurePermission()
                guard micAllowed else {
                    throw MicrophoneCaptureService.CaptureError.microphoneUnavailable
                }

                try await prepareSelectedEngineIfNeeded()

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
        state.log("Recording stopped, processing…", level: .info, category: .recording)

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
                    let mode = state.outputMode
                    state.appendHistory(text: final, engine: state.selectedEngine, outputMode: mode)
                    let preview = String(final.prefix(80)) + (final.count > 80 ? "…" : "")
                    state.log("Transcription: \(preview)", level: .success, category: .transcription)

                    switch mode {
                    case .auto:
                        await routeWithSmartClassifier(final)
                    case .dictate:
                        if state.autoPasteEnabled {
                            await injectFinalTextIfPossible(final)
                        } else {
                            state.statusMessage = "Finished local transcription."
                        }
                    case .createNote:
                        await createNoteFromTranscript(final)
                    case .createReminder:
                        await createReminderFromTranscript(final)
                    }
                } else {
                    state.statusMessage = "Finished — no speech detected."
                    state.log("No speech detected in recording.", level: .warning, category: .transcription)
                }
            } catch {
                await handleFailure(error)
            }
        }
    }

    func cancelSession() {
        microphoneCapture.stop()
        state.log("Session cancelled.", level: .info, category: .recording)
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
            state.log("Model preparation cancelled for \(preparingEngine.userFacingName).", level: .warning, category: .system)
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
        // Request Reminders access early so the system dialog appears at launch
        // rather than mid-dictation when the user says "remind me to…".
        Task { await remindersService.requestAccessIfNeeded() }
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

    // MARK: - Smart auto-routing

    private func routeWithSmartClassifier(_ text: String) async {
        state.statusMessage = "Classifying intent…"
        state.log("Smart mode: classifying intent…", level: .info, category: .system)

        let result = await intentClassifier.classify(text, useAI: true)

        let sourceLabel: String = {
            switch result.source {
            case .foundationModel: return "ai"
            case .keywordRules:    return "rules"
            }
        }()

        switch result.action {
        case .note:
            state.log("Smart (\(sourceLabel)): → Note", level: .info, category: .system)
            await createNoteFromTranscript(result.content)
        case .reminder:
            state.log("Smart (\(sourceLabel)): → Reminder", level: .info, category: .system)
            await createReminderFromTranscript(result.content)
        case .dictate:
            state.log("Smart (\(sourceLabel)): → Dictate", level: .info, category: .system)
            if state.autoPasteEnabled {
                await injectFinalTextIfPossible(result.content)
            } else {
                state.statusMessage = "Finished local transcription."
            }
        }
    }

    // MARK: - Notes integration

    private func createNoteFromTranscript(_ text: String) async {
        state.statusMessage = "Creating note in Apple Notes…"
        state.log("Creating note in Apple Notes…", level: .info, category: .notes)
        do {
            try await notesService.createNote(body: text)
            state.statusMessage = "Note created in Apple Notes."
            state.log("Note created successfully.", level: .success, category: .notes)
            // Notes is already brought to front by the AppleScript `activate` call.
        } catch {
            let msg = error.localizedDescription
            state.statusMessage = "Couldn't create note: \(msg)"
            state.log("Failed to create note: \(msg)", level: .error, category: .notes)
        }
    }

    // MARK: - Reminders integration

    private func createReminderFromTranscript(_ text: String) async {
        state.statusMessage = "Adding reminder…"
        state.log("Adding to Reminders…", level: .info, category: .reminders)
        do {
            try await remindersService.createReminder(title: text)
            state.statusMessage = "Reminder added."
            state.log("Reminder created successfully.", level: .success, category: .reminders)
            openApp(bundleId: "com.apple.reminders")
        } catch {
            let msg = error.localizedDescription
            state.statusMessage = "Couldn't add reminder: \(msg)"
            state.log("Failed to create reminder: \(msg)", level: .error, category: .reminders)
        }
    }

    private func openApp(bundleId: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Failure handling

    private func handleFailure(_ error: Error) async {
        microphoneCapture.stop()
        await transcriber.cancel()
        await MainActor.run {
            self.state.phase = .failed(error.localizedDescription)
            self.state.audioLevel = 0
            self.state.statusMessage = "Prototype failed: \(error.localizedDescription)"
            self.state.log("Error: \(error.localizedDescription)", level: .error, category: .system)
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
            self.state.log("Engine preparation failed (\(engine.displayName)): \(error.localizedDescription)", level: .error, category: .system)
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
        state.log(engine.isInstalled
            ? "Loading \(engine.displayName) engine…"
            : "Downloading \(engine.displayName) engine…",
            level: .info, category: .system)

        let selectedTranscriber = transcriber(for: engine)
        try await selectedTranscriber.prepareModels { [weak self] snapshot in
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
        state.log("\(engine.displayName) engine ready.", level: .success, category: .system)
    }

    private func transcriber(for engine: TranscriberEngine) -> any LocalStreamingTranscriber {
        switch engine {
        case .eouStreaming:
            return eouTranscriber
        case .slidingWindow:
            return slidingWindowTranscriber
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
        // Always land on clipboard first — guaranteed fallback regardless of permissions.
        copyToClipboard(text)

        guard permissionsManager.accessibilityGranted() else {
            await MainActor.run {
                self.state.statusMessage = "Copied to clipboard — grant Accessibility in Settings to auto-paste."
                self.state.log("Accessibility not granted; text copied to clipboard.", level: .warning, category: .system)
            }
            return
        }

        await textInjector.inject(text)
        await MainActor.run {
            self.state.statusMessage = "Pasted at cursor."
        }
    }
}
