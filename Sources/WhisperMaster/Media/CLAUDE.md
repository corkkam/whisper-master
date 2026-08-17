# Other apps' audio (`Sources/WhisperMaster/Media/`)

Loaded when Claude works under this directory. **This is the only place the app
touches playback it does not own.** `Speech/` is our own voice, `Audio/` is the
capture graph; both are about this app's own streams. Here we press the play/pause
key at somebody else's app.

### Why the app pauses your music at all

The microphone hears the speakers. Dictating over a podcast transcribes the
podcast as well as the user, and the words that come back are a blend of two
people that no cleanup pass can unpick. So the media playing on this Mac is paused
for the length of the exchange and released afterwards. On by default;
`AppState.pauseMediaWhileListening` (Settings → Dictation) is the off switch.

### The pieces

- **`AudioOutputActivity`** — read-only Core Audio: the bundle identifier of every
  process currently running output (`kAudioHardwarePropertyProcessObjectList` +
  `kAudioProcessPropertyIsRunningOutput`, macOS 14.2+, empty list below that).
  **⚠️ Reading is not the prohibited thing.** `Audio/CLAUDE.md` forbids *setting*
  HAL properties to re-route devices, which hung `coreaudiod` three different ways
  in 0.3.5–0.3.6. Nothing here writes a property or names a device. It is still an
  IPC round trip per read, so `MediaPauser` always runs it off the main actor —
  never on the key-press path that also has to start the microphone.
- **`MediaPlaybackPolicy`** — pure, tested (`MediaPlaybackPolicyTests`), and the
  only part that can be wrong in a way a user notices.
- **`MediaKey`** — presses play/pause via a `.systemDefined` `CGEvent`. Needs
  Accessibility, which the app already requires for `TextInjector`.
- **`MediaPauser`** — the `@MainActor` coordinator. Pauses from the key press
  (`DictationViewModel.startRecording`) so the first word is never over music, and
  releases from the 0.5 s tick (`reconcileMediaPlayback` →
  `AppState.holdsMediaPlayback`) so one condition in one place covers every exit
  instead of a call at each of the finalize's four returns.

### ⚠️ The rules, and what each one is protecting against

- **The play/pause key is a toggle, not a pause.** macOS delivers it to whichever
  app it considers "now playing", so a blind press while the noise comes from
  something that ignores media keys — a call, a game, an alert — pauses nothing and
  **starts** whatever music was sitting deliberately paused. This is why
  `MediaPlaybackPolicy` is an **allowlist**: we press only when a recognised player
  is actually running output. Adding a bundle id to that list is a claim that the
  app answers the key. Never invert it into a blocklist.
- **Match by prefix, not equality.** The process holding the audio is usually a
  helper — a YouTube tab is `com.google.Chrome.helper`, and every WKWebView player
  (Safari included) is the shared `com.apple.WebKit.GPU`. An exact-match list would
  miss the commonest case there is.
- **Only resume what was actually paused.** `didPause` is set from what the
  speakers did after the press, not from having sent it. A player that ignored the
  key therefore never earns a second press later — that press would have started
  something instead of restoring it.
- **Never resume over something else.** If a recognised player is running output at
  release time, the user started it themselves; the press is dropped rather than
  pausing them a second time.
- **The release grace (`resumeGrace`, 1.2 s) is not tuning, it is correctness.** An
  assistant question is a held chord, then an agent run, then an answer read out
  loud, and the busy flags hand over between those stages with a tick or two of
  idle in between. Without the grace the music flicks back on in the middle of one
  question. Shorten it and that returns.
- **MediaRemote is not an option.** The private framework would let us send an
  explicit *pause* rather than a toggle, and every command from a process without
  an Apple-issued entitlement has been rejected since macOS 15.4 — it would fail
  silently on exactly the machines this app runs on. Don't "fix" the toggle with it.
