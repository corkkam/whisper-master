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

**A player keeps its Core Audio output stream alive after it stops, and how long is
not a number you can rely on.** Measured with Music on this machine: pause it, and
`IsRunningOutput` stays true for ~3.5 s. **A browser holds it far longer than that** —
long enough that a six-second window mistook a *working* pause for a failed one on a
machine playing YouTube in Brave, which is the second bug below. A browser also opens
a silent output stream of its own whenever *another* app plays, this app reading an
answer aloud included.

So "is media playing" cannot be answered instantly, and **there is no public API
that answers it exactly**:

- MediaRemote would (an explicit pause, and a true now-playing state) and is
  **dead**: dlopened on macOS 26 it reports "not playing" while a player is audibly
  running, and `MRMediaRemoteSendCommand` returns true and does nothing. Apple gated
  it behind an entitlement in 15.4. Don't reach for it.
- AppleScript would answer exactly for Music and Spotify, but not for a browser or
  a Chrome PWA — which is what a YouTube Music user actually has — and it costs an
  Automation prompt per app.
- **Power assertions are the one candidate not yet ruled out, and the earlier note
  here was wrong.** It said they linger identically and are held by `coreaudiod`; on
  this machine `pmset -g assertions` shows the *browser itself* holding
  `NoIdleSleepAssertion named: "Playing audio"` (Brave, its own pid) for exactly as
  long as it plays, next to the `coreaudiod` ones that do linger. Chromium drives that
  from its own audible-tab monitor, so it may well drop it promptly on pause — which
  would be a sharper signal than the output stream for the commonest player there is.
  **Unverified**: confirming it needs somebody to pause playback by hand while the
  assertion list is sampled, and neither a test nor an agent shell can press a media
  key (no Accessibility grant, so `AXIsProcessTrusted()` is false and the event is
  dropped). Measure it before building on it.

### ⚠️ Two bugs shipped here, and both were a press in the middle of a hold

1. The first version pressed, re-checked 400 ms later, saw the lingering stream,
   concluded the press had failed, and let the next 0.5 s tick press again. Held for a
   few seconds the music went off, on, off, on, and whichever phase the release landed
   in is what the user was left with.
2. The second pressed once and then watched for up to six seconds for the speakers to
   go quiet, pressing back if they never did. A browser keeps its stream open past that
   window, so on a real machine the pause was **correct and then undone** a few seconds
   into every dictation — and never handed back, because the press-back had cleared the
   debt. This is "it pauses for a bit and then the music comes back by itself".

The lesson is not "use a better window". It is that **a mid-hold press is always acting
on a guess, and the loud failure mode is the user's own music starting in the middle of
the sentence they are dictating.** So there is no watcher any more: press once when the
hold starts, once when it ends, and let the release press be the correction for a press
that went the wrong way. `MediaPauserTests` is the lock —
`testNothingIsPressedMidHoldHoweverLongTheHold` is bug 2 and the `pressedForHold` guard
is bug 1.

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
- **`MediaPauser`** — the `@MainActor` coordinator, and deliberately small: it presses
  once from the key press (`DictationViewModel.startRecording`) so the first word is
  never over music, and once from the 0.5 s tick (`reconcileMediaPlayback` →
  `AppState.holdsMediaPlayback`) so one condition in one place covers every exit
  instead of a call at each of the finalize's four returns. It owns no timer and no
  watching task, which is the property that keeps a press out of the middle of a hold.
  Its `Environment` is injectable so the press-once rule is testable without a speaker.
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
- **⚠️ Two presses per hold, one down and one up, and nothing in between.** Both
  shipped bugs were a third press; see the section above. Anything that presses on a
  timer, a re-check or a confirmation is that bug again.
- **A wrong press is corrected at the release, not mid-hold.** If the stream we saw at
  the key press was the tail of playback the user had already stopped by hand, the
  press *started* their music — and the release press stops it again. The media
  therefore always ends the exchange in the state the user left it in. The residual
  cost is real and is the accepted trade: dictate within the linger of your own manual
  pause and the music plays for the length of that dictation. Shortening that means
  answering "is it audible right now", which nothing above can do yet.
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
  one read that raises it, `release()` just presses, and `MediaPauserTests`' "the
  release always presses back" section is the lock. A spoken "play"
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
