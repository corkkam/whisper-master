# Whisper Master — Features

> Source of truth for the marketing website. Everything below reflects what actually ships in the code as of Mac app **v1.0.2** and the iPhone companion **v0.1 (beta)**. "On the roadmap" items are called out separately — don't present them as available.

---

## What it is

**Whisper Master is local-first voice dictation for Apple Silicon Macs.** You hold a key, talk, and your words appear wherever your cursor is — transcribed on-device by NVIDIA Parakeet, never sent to the cloud. It lives in your menu bar and stays out of the way.

There are two apps:

- **Whisper Master for Mac** — the core dictation app and the transcription engine.
- **Whisper Master for iPhone** — a companion that turns your phone into a wireless mic and a dictation keyboard, powered by your Mac over your local network.

The through-line for both: **your voice never leaves your devices.** No cloud transcription, no accounts, no audio uploads.

---

## Whisper Master for Mac

### Dictate anywhere, instantly
- **Hold-to-talk from any app.** Press and hold your hotkey, speak, release. The text lands right at your cursor.
- **On-device transcription.** Powered by NVIDIA Parakeet running locally — no internet needed once the model is installed, and your audio never leaves the Mac.
- **Real-time streaming.** Words appear as you speak, with live partial results that lock in as confirmed text — not a wait-then-dump at the end.
- **Automatic punctuation and capitalization**, built into the engine. No robotic "period, new line."

### Text that comes out clean
- **Smart number & symbol formatting** (on by default). Spoken language is rewritten the way you'd type it:
  - "twenty five" → **25**
  - "five dollars" → **$5**, "twenty five dollars and fifty cents" → **$25.50**
  - "twenty percent" → **20%**
  - "four thirty" → **4:30**
  - "ninja at gmail dot com" → **ninja@gmail.com**
  - "example dot com" → **example.com**
- **Optional Apple Intelligence polish** (off by default, macOS 26+). Runs a final on-device language-model pass for extra cleanup. Fully local; turn it off and nothing stays loaded.

### Teach it your words
- **Custom vocabulary.** Add the proper nouns, jargon, and acronyms you use — "RAG," "Kubernetes," a client's name — and dictation biases toward them, so "RAG" stops coming out as "rack." Runs in the background and never blocks recording.

### Controls that get out of your way
- **Configurable push-to-talk key** — Right Option (default), Left Option, Right Command, or Right Control.
- **Hold-to-talk or toggle.** Hold while you speak, or tap once to start and once to stop.
- **Works everywhere** — the hotkey is global, so it fires in any app whether or not Whisper Master is focused.
- **Auto-paste at your cursor**, with a **clipboard fallback** — if Accessibility isn't granted, your text is still copied so nothing is ever lost.

### A calm, glanceable interface
- **Menu-bar first**, with a Dock icon so it's always easy to get back to.
- **Floating notch pill** shows your live audio level and status while you dictate, and hides itself when idle.
- **Transcript history** — your recent dictations are saved locally (up to 50), with per-entry copy, paste-at-cursor, and delete, plus a running "words dictated today" count.
- **Five-step onboarding** that walks you through mic and Accessibility permissions with a live mic test, and auto-advances as you grant them.
- **Gentle idle reminders** (off by default) — an optional, quiet nudge in the notch if you haven't dictated in a while. Capped and unobtrusive.

### Handles your mic intelligently
- **Bluetooth quality guard.** Bluetooth headsets drop to low-quality "call mode" the moment any app uses their mic. Whisper Master detects this and offers a **one-tap switch to your built-in mic** — so your earbuds stay hi-fi and your dictation stays crisp. It never changes your devices behind your back.

### Turn your iPhone into a wireless mic
- **Local-network dictation server.** Your Mac quietly advertises itself on your Wi-Fi so the iPhone app can stream audio to it and use the Mac's engine — all over your local network, never the cloud.
- **Keep-awake for phone dictation** (optional) — let the iPhone reach your Mac even after it's been sitting idle and locked.

### See your other Macs (mesh)
- If you run Whisper Master on more than one Mac, each sees the others on the network — with live load, round-trip latency, and rough physical proximity — laying the groundwork for multi-Mac dictation. Names are generic; nothing personal is shared.

### Private by design
- **Everything runs on-device** — transcription, formatting, and vocabulary biasing all happen locally. Your audio and text never leave your Mac.
- **The only things that touch the network:** a one-time model download, Sparkle update checks, local-network discovery for the iPhone app, and **anonymous, opt-out usage stats** (app version, OS, and coarse feature counts — *never* your transcripts, and switchable off in Settings).
- **Non-sandboxed, hardened runtime**, requesting only microphone access plus (optionally) Accessibility for auto-paste.

### Requirements & updates
- **macOS 14 (Sonoma) or later, Apple Silicon only.**
- **Developer ID–signed and notarized** — installs cleanly with no Gatekeeper warnings.
- **Automatic updates via Sparkle** — new versions install themselves in place, no reinstall.

---

## Whisper Master for iPhone *(companion, beta)*

A companion to the Mac app. It doesn't transcribe on its own — it captures your voice and streams it to your paired Mac, which does the work and sends the words back. Same privacy promise: **audio stays on your local network.**

### Dictate straight into your Mac
- **Tap the mic, speak, watch it transcribe.** The phone's mic streams to your Mac over Wi-Fi and the transcript comes back live into the app's editor.
- **No cloud, no accounts** — it talks only to Macs on your local network.

### Dictate into *any* app: the Whisper Master keyboard
- A **hand-built dictation keyboard** you can switch to in any iOS app. Tap its mic button and speak, and your words are inserted right at the cursor — messages, notes, email, anywhere you type.
- **Live activity in the Dynamic Island** shows when Whisper Master is listening.
- Because iOS keyboards can't record audio themselves, the main app briefly holds the mic in the background while you dictate, then hands the text to the keyboard — you just keep typing.

### Finds your Mac automatically
- **Zero-config discovery** over the local network — the app finds Macs running Whisper Master and connects to the best-available one, with the option to pin a specific Mac.
- **Multiple Macs supported** — it load-balances toward whichever has headroom.

### Matches the Mac, by design
- Same **"Daylight" look** — warm cream surfaces, ink text, a vermillion accent, and an animated waveform that comes alive while you're speaking.

### Private by design
- **Audio only ever goes phone → Mac over your local network.** No cloud calls, no third-party SDKs, no analytics or telemetry in the iPhone app.

### Requirements & status
- **iPhone, iOS 17 or later.**
- Currently a **beta (v0.1)** — core dictation, the keyboard, and background mic keep-alive are working. *(Confirm your intended launch channel — TestFlight vs. App Store — before publishing this on the site.)*

---

## Privacy, in one place

- **On-device transcription** on the Mac — your voice is never uploaded for processing.
- **iPhone audio stays on your local Wi-Fi**, streaming only to your own Mac.
- **No accounts, no cloud storage** of your transcripts.
- **Anonymous, opt-out analytics on the Mac** (version/OS/feature counts only, never your words); **none at all on iPhone**.
- The network is used only for: one-time model downloads, app updates, and local device discovery.

---

## On the roadmap *(not yet available — don't list as features)*

- **Dictation beyond the local network** — reaching your Mac from anywhere (relay / NAT traversal). Today, phone and Mac must be on the same network.
- **Multi-Mac routing for iPhone dictation** — automatically using the least-busy Mac. The plumbing (load, latency, proximity) is in; the routing isn't.
- **Custom vocabulary on iPhone** — supported on Mac today; not yet wired up on the phone.

---

## Quick checklist (for feature grids / comparison tables)

**Mac**
- On-device streaming transcription (NVIDIA Parakeet) · real-time partial + confirmed results
- Automatic punctuation & capitalization
- Spoken-to-written formatting (numbers, currency, times, %, emails, URLs) — on by default
- Optional on-device Apple Intelligence polish (macOS 26+, off by default)
- Custom vocabulary biasing
- Global push-to-talk (4 key choices) · hold-to-talk or toggle
- Auto-paste at cursor · clipboard fallback
- Floating notch pill with live audio level · hides when idle
- Local transcript history (50) with copy/paste/delete
- Bluetooth call-mode detection · one-tap switch to built-in mic
- Optional gentle idle reminders
- iPhone-to-Mac dictation server · Mac-to-Mac mesh
- Opt-out anonymous analytics · no transcripts ever sent
- Apple Silicon, macOS 14+ · signed, notarized · Sparkle auto-update

**iPhone (beta)**
- Wireless mic — stream to your Mac over Wi-Fi
- System-wide dictation keyboard (works in any app)
- Dynamic Island live activity
- Automatic Mac discovery · multi-Mac aware
- Matching "Daylight" design
- No cloud, no analytics · iOS 17+
