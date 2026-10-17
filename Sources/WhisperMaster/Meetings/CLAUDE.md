# Meetings (`Sources/WhisperMaster/Meetings/`)

Meeting notes: notice a call, offer to take notes on the notch, record both
sides, show a live transcript, and file a `Note` with the summary, the local
transcript and the recording. Dev builds only (`FeatureFlags.meetingNotesAvailable`).

## Flow

`MeetingController` (on `AppState.meetings`, started post-auth) polls every 2 s:
`AudioOutputActivity.runningInputBundleIDs()` -> `BrowserMeetingProbe` for browsers
-> `CallDetector` (pure, debounced) -> `prompt` -> `NotchMeetingPromptBanner`.
"Take notes" -> `MeetingSession`: own `MicrophoneCaptureService` ("You") +
`SystemAudioTap` ("Others") -> one `MeetingAudioStream` each (resample to 16 kHz,
write to disk, own Parakeet transcriber) -> `MeetingTranscript`. Stop (button, tray,
or the call app releasing the mic for 15 s) -> mix to `<noteID>.m4a`, file the note,
then `MeetingNotesGenerator` map-reduces the transcript on the general model and
rewrites the note body.

## Rules that are not obvious

- **Detection is read-only Core Audio.** It reads the process list; it sets no HAL
  property. Our own process is excluded by PID, so our own dictation and our own
  meeting recording never look like a call.
- **A call is found once and then followed by its app's hold on the mic.** A browser
  call is *found* by a tab title or a calendar event, but neither survives a tab
  switch or a meeting that runs over; re-running detection every poll ended the
  recording 15 s into either and split one meeting into two notes. `CallDetector`
  keeps an active call going while any process of its family is on the mic
  (`holdsMic`).
- **Slack, WhatsApp and Telegram must also be playing audio to count**
  (`MeetingAppCatalog.voiceMessageApps`). A voice message holds the mic for as long
  as the user talks, so no start hold separates it from a call; what does is that a
  call plays the other side. Output is read only when one of these is on the mic.
- **The tap needs a private aggregate device.** That is Apple's only way to read a
  process tap. It is private (invisible to other apps), never becomes a default,
  and is destroyed in `stop()`. It is not the device juggling `Audio/CLAUDE.md`
  forbids. Do not "simplify" it into changing the default input or output.
- **Tap setup and teardown run on `SystemAudioTap`'s control queue**, never on the
  main actor: each call is an IPC round trip to `coreaudiod`. The control queue is
  not the IO queue, because destroying an IO proc waits for its block to return.
- **A stop can land while `MeetingSession.start` is still loading models.** Stop is
  on screen as soon as the session exists, so `start` checks `isStopped` after every
  suspension and releases what it opened; `cancel` is a no-op after `stop`, which
  may still be mixing. Without this the mic and tap stayed open with nothing to
  close them.
- **The final transcript is aligned, not sliced by word count.** `stop()` returns
  text rebuilt from tokens, which differs from the confirmed track here and there;
  `MeetingTranscript.seam` finds where the last taken words reappear.
- **Chrome and Zoom play from helper processes**, so taps and detection match bundle
  ids by prefix (`MeetingAppCatalog.family`). A web call whose tab has not played
  sound yet has no process object; the tap then falls back to a global tap that
  excludes us. The process list is read once at start; a helper that appears later
  is not added (known gap).
- **Two extra transcribers, never the dictation one.** Push-to-talk keeps working
  during a meeting. Each stream loads Parakeet from disk once; `MeetingSession`
  refuses to start when the engine is not installed rather than download.
- **One consumer per stream.** Buffers go through an `AsyncStream`, not a `Task`
  per buffer, because per-buffer tasks reorder audio.
- **Audio is written to disk on purpose**, which is the exception to the
  dictation-path rule in the root `AGENTS.md`. Tracks stream to temp CAFs (an hour
  is too big for memory) and are mixed into one AAC file in
  `NoteAudioStore.directory`. Not synced, same as other note audio. A quit deletes
  the temporary tracks (`discardForTermination`), and launch removes any a crash
  left (`MeetingAudioRecorder.removeLeftovers`, skipping a folder written to in the
  last ten minutes).
- **The note is filed before the notes pass**, with a placeholder body, so a crash
  or a model timeout loses nothing. Transcript lives in `Note.transcript`, which
  `NoteWire` does not sync; only title and the Markdown notes body sync.
- **The model is never downloaded for this.** No assistant model: transcript and
  recording are saved and the body says how to get notes.
- **Echo:** on laptop speakers the mic hears the call. `MeetingTranscript.cleanedSegments`
  drops a mic line when a call line within 15 s carries 60% of its words.

## Not done yet

- Not run on a real Slack, Teams, Zoom or Meet call. The tap, the aggregate device
  and two concurrent Parakeet sessions are verified only by build and unit tests.
- Action items are Markdown checkboxes in the note; there is no one-tap reminder.
- Quitting the app mid-meeting drops the meeting and deletes its recording (no save
  on terminate; a crash loses it too, rather than recovering it into a note).
- On a real call, still to confirm: whether starting the aggregate (which lists the
  default output as its clock) switches AirPods to the call profile, whether a
  denied audio-capture permission records silence instead of failing, and whether
  a Slack huddle's output runs before anyone else has spoken.
- The two meeting streams each load their own Parakeet; sharing one `AsrModels`
  would save memory on 8 GB Macs. A mic engine rebuild leaves an unpadded gap in
  the "You" track, so the mix drifts after a route change.
- No diarization inside "Others" (FluidAudio's diarizer is vendored, not wired).

Tests: `CallDetectorTests`, `MeetingTranscriptTests`, `MeetingNotesGeneratorTests`,
`MeetingAudioMixTests`, `MeetingAudioRecorderTests`. Snapshots: `pill-12-meeting-detected`,
`pill-12b-meeting-notes-saved`, `meeting-live`.
