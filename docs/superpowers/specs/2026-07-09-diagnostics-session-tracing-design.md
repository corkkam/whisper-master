# Diagnostics — on-disk session tracing (local-only debug build)

**Date:** 2026-07-09
**Status:** approved, implementing
**Audience:** developer only. This never ships. It exists so we can see, for every
real dictation, exactly where latency goes, how the ASR/model performs, and what
each pipeline stage did to the text — plus keep the raw audio so real recordings
can be replayed through the existing eval.

## Goal

Answer the questions we currently can only guess at:
- "It misses words" — does the ASR *mishear* or *drop*, or does a later stage/paste eat them?
- "The mic quality feels bad" — is the captured audio actually bad (Bluetooth/format/gain),
  or is the audio fine and the model/pipeline at fault?
- "Recording happens a bit late" — how big is the mic warmup, really?

The instrument: a structured per-session trace + the session audio, written to disk,
that Claude reads and that feeds the eval/replay harness.

## Non-goals

- No in-app UI. On-disk only (approach A).
- No network, no upload, no analytics. Everything stays on the local machine.
- Not shipped. Ever.

## Build gating

The whole module is wrapped in `#if DIAGNOSTICS`. The shipping CI Release does **not**
set that compilation condition, so the code (and all audio-writing I/O) is physically
absent from any build a tester receives.

Crucially the local build is **Release-optimized, not Debug** — Debug's unoptimized Swift
would make every latency/RTF number misleading. We flip only the compile flag:

```
DIAGNOSTICS=1 bash Scripts/install.sh
```

`bundle.sh`/`install.sh` append `DIAGNOSTICS` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
when the env var is set; otherwise the build is byte-for-byte the normal Release.

## Data model — `SessionTrace` (Codable)

One per dictation. Fields:

- **id / startedAt** — uuid + ISO-8601 timestamp (also the file stem).
- **context** — app version, engine, active toggles (filler / llm cleanup / ITN /
  hold-to-talk), paste outcome (native / web / clipboard / none).
- **timeline** — ordered `(stage, msSinceStart)` marks: `armed`, `engineStarted`,
  `micStarted`, `firstBuffer`, `firstPartial`, `firstConfirmed`, `stopRequested`,
  `finalizeStart`, then per pipeline stage `spacing`, `selfCorrection`, `itn`,
  `filler`, `vocab`, `llmPolish`, `guard`, `pasted`. Derived per-stage deltas.
- **asr** — audioDurationMs, realTimeFactor, confirmedChars, volatileChars,
  usedSalvagePath (bool), wordCount.
- **audio** — inputDeviceName, isBluetooth, sampleRate, channelCount, rmsMean,
  peak, clippedPct, droppedBuffers.
- **text** — the chain: `rawAsr`, then output after each stage, then `finalPasted`.
  (So a diff shows which stage changed what.)

Serializes to pretty JSON. Round-trip covered by a unit test.

## Storage — `~/Library/Application Support/WhisperMaster/Diagnostics/`

```
sessions/<timestamp>_<id>.json   ← the trace
sessions/<timestamp>_<id>.wav    ← 16 kHz mono PCM, exactly what the model consumed
index.ndjson                     ← one summary line per session (fast scan)
```

Retention: keep the newest **100** sessions (trace+wav pruned together); older removed
on write. WAV is chosen over m4a: lossless and replay-faithful for the eval.

## Modules (all under `Sources/WhisperMaster/Diagnostics/`, single-responsibility)

| File | Responsibility |
|---|---|
| `SessionTrace.swift` | Codable data model + derived deltas. Pure. |
| `AudioSignalStats.swift` | RMS / peak / clip% math over PCM buffers. Pure, unit-tested. |
| `SessionAudioWriter.swift` | Accumulate PCM buffers → write a 16 kHz mono WAV. |
| `DiagnosticsStore.swift` | Write trace JSON + append NDJSON index + retention prune. |
| `DiagnosticsRecorder.swift` | `@MainActor`. `begin()` / `mark(_:)` / `note*` / `finish()`; assembles a `SessionTrace` across one dictation and hands it to the store. |
| `Diagnostics.swift` | Thin facade. `Diagnostics.shared` is the real recorder under `#if DIAGNOSTICS`, a no-op otherwise, so call sites carry no `#if`. |

Call sites (kept minimal, no `#if` at the site): `DictationViewModel.startRecording`
(arm / engine / mic marks), the transcriber update handler (first partial/confirmed),
`stopRecording` (per-stage marks + text chain + finish), `MicrophoneCaptureService`
(feed buffers to the audio writer + level stats).

## Eval integration

`Scripts/diag-to-cases.sh` (or a small `eval-score` subcommand) converts saved sessions
into an audio `cases.jsonl` — each WAV becomes an `input.audio` case with the session's
final transcript as `reference`/`asr_reference`. The existing replay harness
(`AudioReplayTests` / `EvalRunner`) then runs the real recordings through the exact live
pipeline. No engine change; this is the payoff of storing the audio.

## Tests

Pure pieces only (fast, no models/audio hardware):
- `AudioSignalStats` — known buffers → expected RMS/peak/clip.
- `SessionAudioWriter` — WAV header + sample count correct for a synthetic buffer.
- `SessionTrace` — JSON round-trip; derived deltas correct.

## Verification

`DIAGNOSTICS=1 bash Scripts/install.sh`, dictate a few times (native field, web app,
over Bluetooth, in noise), then read `Diagnostics/index.ndjson` + a couple of traces:
confirm the timeline, audio stats, and text chain are populated and the WAVs play back.
Then run the converter + eval on the saved audio.
