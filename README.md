<div align="center">

<img src="Sources/WhisperMaster/Resources/WhisperMasterLogo.png" width="118" alt="Whisper Master" />

# Whisper Master

**Local-first streaming dictation for macOS.**
Talk into any app and get clean, punctuated text back — in real time, entirely on your Mac. No cloud, no API keys, nothing leaves the device.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-211c15)
![Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-c0381a)
![On-device](https://img.shields.io/badge/100%25-on--device-3c7a4e)
[![Eval dashboard](https://img.shields.io/badge/eval-dashboard-c0381a)](https://whisper-eval-dashboard.vercel.app)

</div>

---

Whisper Master is a menu-bar app that transcribes your speech with **NVIDIA Parakeet** (via [FluidAudio](https://github.com/FluidInference/FluidAudio)) and cleans it up the way you'd actually type it — filler words gone, numbers and times formatted, self-corrections resolved — then pastes it wherever your cursor is. An optional on-device language model (qwen2.5-3B via **MLX**) adds a deeper polish, always behind a faithfulness guard so it only ever *cleans* your words, never answers or acts on them.

## Highlights

- **Real-time streaming transcription** — Parakeet (`parakeet-tdt-0.6b-v3`) running locally on Apple Silicon.
- **Instant paste, background refine** — the deterministic cleanup pastes immediately; the LLM polish lands a beat later, in place, so you never wait on a model.
- **Deterministic cleanup** — filler/stutter removal, inverse text normalization (spoken numbers → digits, currency, %, times, emails), spoken **self-correction collapsing** ("twenty no thirty no forty" → 40), and a custom-vocabulary glossary.
- **Optional smart cleanup** — a local qwen2.5-3B model rewrites for clarity/grammar, gated by a **faithfulness guard** that never lets it answer a question, run a command, or invent facts.
- **Push-to-talk** hotkey and system-wide text injection (Accessibility).
- **Bluetooth-aware** — detects when a Bluetooth mic is degrading audio and offers a one-tap switch to the built-in mic.
- **Ships like a real app** — Developer ID signed, notarized, and auto-updating via **Sparkle**; models stream from a Cloudflare R2 mirror with resumable downloads.
- **Graded, not guessed** — a full evaluation engine measures the *real shipped pipeline*, with a public [run-history dashboard](https://whisper-eval-dashboard.vercel.app).

## How it works

```
 mic  ─▶  Parakeet streaming ASR  ─▶  deterministic cleanup  ─▶  optional on-device LLM  ─▶  paste
                                       · spacing repair            · qwen2.5-3B (MLX)
                                       · self-correction collapse  · faithfulness guard
                                       · inverse text normalization  (falls back to the
                                       · filler removal               deterministic text
                                       · custom vocabulary            whenever it diverges)
```

Transcription and cleanup are separate, testable stages. The deterministic passes are pure Swift (instant, no model); the LLM stage is opt-in and never blocks dictation.

## Evaluation

Every change is graded against the **real pipeline** — not a proxy — on real human speech (LibriSpeech), plus synthetic, noisy, and Bluetooth-mic conditions. It measures transcription accuracy (word error rate), cleanup quality, and faithfulness, and stores each run over time.

**Live dashboard → [whisper-eval-dashboard.vercel.app](https://whisper-eval-dashboard.vercel.app)**

The harness lives in [`eval/`](eval/); the dashboard is a SvelteKit + Prisma + MongoDB app in [`eval/dashboard/`](eval/dashboard/).

## Build & develop

**Requirements:** Apple Silicon, macOS 14+, full Xcode 26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The `.xcodeproj` is generated from `project.yml`.

```bash
brew install xcodegen
xcodegen generate            # (re)create WhisperMaster.xcodeproj
open WhisperMaster.xcodeproj # work in Xcode

swift build                  # fast headless compile check (no .app)
swift test                   # pure unit tests (fast, no models/audio)

bash Scripts/bundle.sh       # build + sign the distributable .app
bash Scripts/install.sh      # build → install to /Applications → relaunch
```

Distribution, notarization, Sparkle releases, and the CI/CD flow are documented in [`CLAUDE.md`](CLAUDE.md), which is the source of truth for the architecture.

## Tech stack

Swift · SwiftUI · [FluidAudio](https://github.com/FluidInference/FluidAudio) (NVIDIA Parakeet) · [MLX](https://github.com/ml-explore/mlx-swift) (qwen2.5-3B) · [Sparkle](https://sparkle-project.org) · Cloudflare R2 · SvelteKit + Prisma + MongoDB (eval dashboard).

---

<div align="center">
<sub>Built for people who'd rather talk than type. Everything on-device, by design.</sub>
</div>
