# Notes (`Sources/WhisperMaster/Notes/`)

Loaded when Claude works under this directory. Moved verbatim out of the root
`CLAUDE.md`, which keeps the one-line prohibitions and a pointer here.

### Notes: the recording is part of the note (`Notes/`)

A note made by voice keeps **three** things, not one: the assistant's tidied
`title`/`body`, the **verbatim `transcript`**, and the **`audio`** of the dictation
that produced it. "Did it hear me right?" is the first question a spoken note
raises, and the recording is the only thing that answers it without asking the user
to trust either string. UI details are in `Sources/WhisperMaster/UI/CLAUDE.md`.

- **`Note`'s `Codable` conformance is hand-written and must stay that way.** Notes
  are already on disk (and in the sync dashboard) from before pinning, transcripts
  and audio existed, and the *synthesized* conformance treats a missing
  non-optional key as a decode error. `NotesStore.loadFromDisk` swallows that throw
  — so adding a bare `isPinned: Bool` would have silently emptied every existing
  user's notes rather than crashing. Every field added from here on uses
  `decodeIfPresent` with a default;
  `NoteVoiceModelTests.testALegacyNoteWithNoneOfTheNewKeysStillDecodes` is the lock.
- **The audio tee runs for every session, not just chord-armed ones.**
  `DictationViewModel.noteAudioWriter` starts in `startRecording` and is fed from
  `enqueueAudioBuffer` (the single mic choke point). It can't start at *arm* time
  because the chord can arm a session already in flight — fn pressed a hair before
  control — which would clip the opening word off exactly the notes people dictate
  fastest. Cost is a mono int16 downmix per buffer, nothing beside Parakeet. It's
  bounded (`noteAudioMaxMs`, 5 min) so a latched hands-free session can't grow the
  heap all afternoon, and a `defer` in the stop task drops the samples for any
  session that didn't become a note.
- **This is collection, not a second capture.** The buffer is already in hand from
  the one existing tap; nothing here touches a device or `AVAudioEngine`, so it
  stays clear of the device-juggling prohibitions above. Playback
  (`NoteAudioPlayer`) is `AVAudioPlayer` on a finished file — the same
  `Speech/`-vs-`Audio/` separation.
- **Both note-creation paths carry the voice context.** The agent path
  (`LocalToolRunner.createNote`, the common case when the 3B is loaded) gets it via
  `LocalToolRunner.VoiceContext`; the deterministic fallback
  (`DictationViewModel.createNote`) passes it directly. The audio closure is
  `takeAudio`-shaped because the recording is **consumed on first use** — one
  capture yields one recording, attached to whichever note it produced.
- **Audio is deliberately not synced.** `NotesSyncClient` pushes the rows; the WAV
  stays on the Mac that recorded it. So a synced note names a file that isn't here,
  and `NoteAudioStore.playableURL` reports that rather than rendering a play button
  that does nothing. Deleting a note keeps the row as a sync tombstone but deletes
  the recording outright — it's the biggest thing the app writes and there's nothing
  for another Mac to reconcile.
