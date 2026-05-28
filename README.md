# Whisper Master Prototype

Separate sandbox for testing a local-first streaming dictation stack with `FluidAudio` and NVIDIA Parakeet on Apple Silicon.

## Why this exists

This repo is intentionally separate from `/Users/ninja/coding/lyzr-exprmt/lyzr-whisper`.

Goals:

- keep the current app untouched
- prove whether local streaming ASR feels better than the current `whisper.cpp` batch flow
- evaluate `FluidAudio` + Parakeet on an M4 Air

## Plan

1. Verify the package resolves and runs on this machine.
2. Add microphone capture and 16 kHz mono conversion.
3. Load a local Parakeet model through `FluidAudio`.
4. Stream partial transcripts into a small debug UI.
5. Measure latency, thermals, and final-text stability.

## Current status

The repo now contains:

- a standalone macOS menu-bar prototype
- a SwiftUI debug window for start/stop and transcript inspection
- a modular microphone capture layer
- a modular `FluidAudio` sliding-window transcription layer
- live model-download progress reporting

Verified so far:

- `FluidAudio` resolves and builds in this repo
- the prototype launches successfully on this machine
- the local streaming manager initializes at runtime

## Next milestone

Use the running app to validate first-run model download, microphone permissions, and real transcript quality on-device.
