---
component: Transcription
owner: c-transcription
interface_version: 1
last_verified: 2026-11-27
verified_by: cd whisper-master && swift test --filter DeterministicITNTests --filter SelfCorrectionCollapserTests --filter CleanupFaithfulnessGuardTests --filter TranscriptChunkerTests --filter MlxWorkGateTests
---
# Transcription interface

Bare file names are inside `whisper-master/Sources/WhisperMaster/Transcription/`.

## Purpose

Turns mic audio into text. It runs Parakeet speech recognition, the deterministic text passes, and the opt-in MLX cleanup and assistant models. A guard checks every cleanup output. When the guard or the model fails, the deterministic text stays.

## Entry points

- ASR: actor `FluidAudioStreamingTranscriber` (`prepareModels`, `start`, `append`, `stop`, `cancel`). Protocol `LocalStreamingTranscriber` and `StreamingTranscriptUpdate` in `LocalStreamingTranscriber.swift`. `TranscriberEngine.slidingWindow.isInstalled` checks compiled files. Do not cache it.
- Pure passes: `TranscriptMerger` (`mergedConfirmed`, `partialRemainder`, `bestEffort`), `TranscriptSpacingRepair.repair`, `SelfCorrectionCollapser.collapse`, `DeterministicITN.normalize`, `FillerWordFilter.clean`, `VocabularyPostProcessor.apply`, `VocabularyTermParser.parse`.
- Formatter: `TextFormatterProvider.shared.current()` picks the deterministic or the Apple formatter. `FormattingHeuristic`, `FormattingPreference` and `AppleIntelligenceStatus` are in `TextFormatting.swift`.
- MLX: `MlxCleanupService.shared` (dictation) and `.general` (assistant). Calls: `clean(_:systemPrompt:target:)`, `generateAgent`, `generateWithTools`, `prepareGeneralIfInstalled`, `prepare(directory:)`, `release`, `isReady`, `loadedThinks`.
- Models and guard: `CleanupModel`, `CleanupModel.General`, `CleanupFaithfulnessGuard.verdict`, `CleanupPrompt`, `IntentPrompt`, `CleanupTarget`, `TranscriptChunker`, `MlxModelConfiguration.local`, `MlxWorkGate.shared` (`enter`, `leave`, `holdQuit`), `CleanupModelManager.syncWithToggle`, `AssistantModelManager`.

## Inputs and outputs

- In: audio buffers, raw ASR text, vocabulary terms, formatter preferences, a `CleanupTarget`.
- Out: partial and final transcript text. A cleanup call returns text or nil. Each `*Counting` variant also returns how many edits it made.
- Model files live under `CleanupModel.modelsRoot`. A new archive needs a SHA-256 pin in `ModelChecksums`.

## Errors and invariants

- Run `SelfCorrectionCollapser` before ITN, in every copy of the pipeline.
- `SpokenNumber.value` returns nil for bare unit runs ("one two three").
- Every MLX load and generation takes `MlxWorkGate.enter()`. On refusal, do nothing. Never return partial text after a quit.
- Use a fresh KV cache for each generation.
- Read "does it reason" from `loadedThinks`, never from the live setting.
- The S1-mini system prompt is exact. `enable_thinking` stays false.
- `TranscriptChunker.defaultMaxWords` (240) and the 512 token cap are pinned together. Skip chunking for `.email`.
- The `slack`, `email` and `code` targets are eval-only.
- Keep `assistantModelReady` apart from `cleanupModelReady`.

## Architecture

- Audio goes to the ASR actor. It emits streaming updates, and `TranscriptMerger` joins them.
- The final text passes through the deterministic chain: spacing, self-correction, formatter, ITN, fillers, vocabulary.
- The opt-in cleanup model rewrites the text. The faithfulness guard accepts or rejects the result.
- The assistant uses a second model slot (`.general`). It never uses the cleanup slot.
- `MlxWorkGate` lets the app quit without cutting a running generation.
- Trap: the shipped path in `DictationViewModel` and `LabDeterministicPipeline` are two copies of the passes. Edit both.
- Trap: `formatFinalTranscript` gates ITN on `itnEnabled`. The Lab copy does not.

## Do not

- Do not re-enable `configureVocabularyBoosting`. Vocabulary is post-processing.
- Do not add a short-window preview track. Do not lower `chunkSeconds`.
- Do not use the cleanup slot for the agent or the intent.
- Do not change the guard to catch dropped words.
- Do not change the model order in `resolveInstalledDirectory`. A switch must keep a working assistant.
- Do not change a cleanup prompt or guard without `eval/text-cleanup/run-eval.sh`. Use `swift test --filter AudioReplayTests` for an ASR change.

## Used by

- `whisper-master/Sources/WhisperMaster/App/`: `DictationViewModel` runs the pipeline and owns both model managers. `AppDelegate` calls `holdQuit`. `AppState` reads the formatter preferences.
- `whisper-master/Sources/WhisperMaster/Connectors/Agent/`: `AgentLoop` and `CommandAgentService` use `.general`.
- `whisper-master/Sources/WhisperMaster/Meetings/`: sessions and notes use `.general` and the gate.
- `whisper-master/Sources/WhisperMaster/Server/RemoteTranscriptionSession.swift` repeats the text passes.
- `whisper-master/Sources/WhisperMaster/Eval/` and `whisper-master/Sources/WhisperMaster/Lab/` bench the models.
