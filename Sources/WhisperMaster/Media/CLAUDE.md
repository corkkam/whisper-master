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

### ⚠️ Read this before changing anything here: the linger

**A player keeps its Core Audio output stream alive for about 3.5 seconds after it
stops.** Measured on this machine: pause a player, and `IsRunningOutput` stays true
for ~3.5 s. A browser is worse — Chrome opens a silent output stream of its own
whenever *another* app plays, and holds it for as long as that lasts.

So "is media playing" cannot be answered instantly, and **there is no public API
that answers it exactly**:

- MediaRemote would (an explicit pause, and a true now-playing state) and is
  **dead**: dlopened on macOS 26 it reports "not playing" while a player is audibly
  running, and `MRMediaRemoteSendCommand` returns true and does nothing. Apple gated
  it behind an entitlement in 15.4. Don't reach for it.
- Power assertions (`pmset -g assertions`) linger identically and are held by
  `coreaudiod`, not the player.
- AppleScript would answer exactly for Music and Spotify, but not for a browser or
  a Chrome PWA — which is what a YouTube Music user actually has — and it costs an
  Automation prompt per app.

**This shipped as a bug once, and it is the reason for the press-once rule.** The
first version pressed the key, re-checked 400 ms later, saw the lingering stream,
concluded the press had failed, and let the next 0.5 s tick press again. Held for a
few seconds, the music went off, on, off, on, and whichever phase the release landed
in is what the user was left with. `MediaPauserTests` is the lock; do not remove the
`pressedForHold` guard or shorten `confirmWindow` below the linger.

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
- **`MediaPlaybackState`** — the one place the Core Audio read and the allowlist are
  joined, always off the main actor (a sample costs ~1.8 ms of IPC).
- **`MediaKey`** — presses play/pause, next or previous via a `.systemDefined`
  `CGEvent`. Needs Accessibility, which the app already requires for `TextInjector`.
- **`MediaPauser`** — the `@MainActor` coordinator. Pauses from the key press
  (`DictationViewModel.startRecording`) so the first word is never over music, and
  releases from the 0.5 s tick (`reconcileMediaPlayback` →
  `AppState.holdsMediaPlayback`) so one condition in one place covers every exit
  instead of a call at each of the finalize's four returns. Its `Environment` is
  injectable so the press-once rule is testable without a speaker.
- **`MediaCommandDetector` + `MediaController`** — the spoken "pause the music".
  **⚠️ The detector is legal only inside `routeCommandCapture`**, downstream of the
  assistant chord where the paste is already suppressed, for exactly the reason
  `DayQueryDetector` is restricted to the same place. It matches the **whole**
  capture, never a word inside a sentence, so "pause the deploy until I have looked
  at it" stays a note. `MediaController` re-checks the world before play or pause,
  because sending a toggle for an explicit instruction can do the opposite of what
  was asked.

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
- **One press per hold, in and out.** `pressedForHold` is not an optimisation; see
  the linger section above. Anything that presses on a timer or a re-check will
  oscillate.
- **Only resume what was actually paused.** After the press, `confirmPause` waits
  for the speakers to go quiet — which a real pause always does once the linger runs
  out. If they never do, the press started something instead of stopping it, so it
  is undone once and nothing is owed at release.
- **A spoken command outranks the automatic hold.** `yieldToUser()` makes the pauser
  stop having an opinion for the rest of the hold, so saying "play" does not get
  quietly re-paused when the dictation ends.
- **⚠️ The release presses back unconditionally — do not put a check in front of
  it again.** This shipped as the second bug in this file: the music paused and never
  came back. Two causes, one shape. The confirmation below watches for up to 6 s, and
  it used to hold the "one Core Audio conversation at a time" flag for its whole run,
  so a release arriving inside that window found the pauser busy and dropped the press
  — which is every dictation shorter than about five seconds. And the release then
  asked "is anything playing?" first, meaning not to resume over something the user
  had started; that question is unanswerable here, because the player we paused a
  second ago still reads as running (the linger), and Chrome opens a silent output
  stream of its own whenever anything else plays — including this app reading an
  answer out loud, which is every assistant question. So: `working` is scoped to the
  one read that raises it, `release()` cancels the confirmation and presses, and
  `MediaPauserTests`' "the music never came back" section is the lock. A spoken "play"
  is the one thing that must not be re-paused, and `yieldToUser()` already owns it.
  Silent speakers with no explanation is a far worse failure than a player paused once
  more than it asked for.
- **The release grace (`resumeGrace`, 1.2 s) is not tuning, it is correctness.** An
  assistant question is a held chord, then an agent run, then an answer read out
  loud, and the busy flags hand over between those stages with a tick or two of
  idle in between. Without the grace the music flicks back on in the middle of one
  question. Shorten it and that returns.
- **MediaRemote is not an option.** The private framework would let us send an
  explicit *pause* rather than a toggle, and every command from a process without
  an Apple-issued entitlement has been rejected since macOS 15.4 — it would fail
  silently on exactly the machines this app runs on. Don't "fix" the toggle with it.
