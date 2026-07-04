# Test recordings — read these aloud

Record each paragraph as a **16-bit WAV** with the exact filename shown. Save
them all in this folder (`.context/test-audio/`). Speak naturally, at your
normal dictation pace and distance from the mic.

Then tell me "recordings done" and I'll replay every file through the real
streaming pipeline and show exactly what comes out at each stage.

Tips:
- Built-in mic is best (not Bluetooth — that halves the quality).
- Where you see **(um)** / **(uh)**, actually say the filler out loud — that's
  the case we're chasing.
- No need to read the filename or the "P#" label, just the sentence text.

---

## P1 — long, clean (baseline: does length alone break it?)
**File: `paragraph-1.wav`**

> The morning light came through the kitchen window and fell across the table.
> I poured a cup of coffee and sat down to plan the rest of the day. There were
> emails to answer, a report to finish, and a call scheduled for the afternoon.
> By the time I looked up again, an hour had already slipped past.

## P2 — long, with fillers (the reported trigger)
**File: `paragraph-2.wav`**

> So (um) I was thinking about the project, and (uh) I feel like we should
> probably rewrite the whole onboarding flow. It's (um) kind of confusing right
> now, and people keep (uh) getting stuck on the second screen. Maybe we can
> (um) simplify it down to three steps instead of five.

## P3 — short (baseline: short single sentence)
**File: `paragraph-3.wav`**

> Remind me to buy milk and eggs on the way home tonight.

## P4 — numbers, dates, email (tests formatting / ITN)
**File: `paragraph-4.wav`**

> The meeting is at four thirty on March twelfth. Send the invoice for two
> thousand five hundred dollars to john at gmail dot com, and note that the
> discount is twenty five percent.

## P5 — vocabulary terms (tests biasing / aliases)
**File: `paragraph-5.wav`**

> We are using Parakeet for transcription and a RAG pipeline for retrieval. The
> Lyzr agent handles the routing, and it all runs on an NVIDIA card locally.

## P6 — very long, many sentences (does the beginning survive the window?)
**File: `paragraph-6.wav`**

> Yesterday I walked down to the harbor to watch the boats come in. The water
> was calm and the air smelled like salt and diesel. An old fisherman was
> mending his net on the dock, and he nodded at me as I passed. Further along, a
> group of kids were dropping crab lines off the pier and shouting every time
> one of them caught something. I bought a paper cup of chowder from a little
> stand and found a bench in the sun. For a while I just sat there, watching the
> gulls fight over scraps, and I forgot all about the work waiting for me at
> home. It was the most peaceful hour I had spent in weeks.

## P7 — realistic mixed dictation (fillers + a hard word + a number)
**File: `paragraph-7.wav`**

> Hey (um) quick update on the Lyzr demo. We shipped the new build this morning,
> and (uh) accuracy is up around ninety percent now. I still need to fix the one
> bug where the last word gets cut off, but (um) other than that it's looking
> pretty good.
