---
component: Agents
owner: c-agents
interface_version: 1
last_verified: 2026-11-27
verified_by: cd whisper-master && swift test --filter AgentRevealTests --filter AgentReplayGatingTests --filter AgentDeskTests --filter AgentAskTests --filter KunaiEventStreamTests --filter ShedAgentsTests
---
# Agents interface

Bare file names are inside `whisper-master/Sources/WhisperMaster/Agents/`. The rail of Crew faces lives in `whisper-master/Sources/WhisperMaster/Crew/` and `whisper-master/Sources/WhisperMaster/UI/AgentFaces/`.

## Purpose

The app is a client of two coding-agent servers, kunai and Shed. This folder finds them, reads their sessions, and holds the state that the notch shows. It sends spoken prompts and permission answers back. It never starts or ships a server.

## Entry points

- `AgentSurfaceController` (`@MainActor @Observable`) is the one state object. Lifecycle: `start()`, `stop()`, `refresh()`. It owns `shed` (`ShedAgents`) and `crew` (`CrewAgents`).
- Glance and reveal: `reveal(sessionID:adoptExistingReply:)`, `toggleGlance()`, `closeGlance()`, `focus(sessionID:)`, `open(sessionID:)`, `revealHasExpired(now:)`.
- Answers: `resolve(_:allow:always:)` for an approval card, `answer(_:question:selected:)` for a choice card. `activeAsk` is the kunai ask, else the Shed ask.
- Prompts: `deliver(prompt:startingIn:)` returns false when nothing took the words. Also `sendPrompt`, `interrupt()`, `setMode(_:)`.
- Desk: `AgentDesk`, `ensureDesk(in:)`, `handToDesk(_:folder:)`, `heldSessions`, `onDeskReply`.
- Nudges: `holdNudge()`, `dismissNudge()`, `otherSessionNeedsYou`.
- Models: `AgentSession`, `AgentAsk` (`.approval` or `.choice`), `AgentTurnLog`, `AgentChangeSet`, `AgentAttention`, `AgentReplyDocument`, `AgentReplyLine`.
- Shed: `ShedAgents` (`configure(enabled:urlOverride:)`, `start`, `stop`, `answer`, `interrupt`, `useTailscaleForPhone`), `ShedLink`, `ShedPage`, `ShedEndpoint`.
- kunai: `KunaiEndpoint`, `KunaiMachine`, `KunaiWire`, `KunaiRESTClient`, `KunaiEventStream`, `KunaiFleetStream`. Protocol `AgentTransport`.
- `seed*ForSnapshot` helpers are for `SnapshotMode` only.

## Inputs and outputs

- In: kunai REST polls and WebSocket frames, Shed REST replies, spoken prompts, answers to cards.
- Out: session rows, one ask at a time, a reply line, nudges, and prompts or answers sent back to a server.
- A REST call returns an optional or an empty array. Nothing in this folder persists.

## Errors and invariants

- Absence is normal. A missing server is no error state.
- The controller stays dormant until `start()`, so tests and the snapshot renderer open no socket.
- Use two sockets, never one per session. The second one is permissions-only for a blocked neighbour.
- `AgentFleet` keeps one bucket per machine. A dropped socket keeps its sessions.
- Both session sources go through `applySessions`.
- Replayed frames are history. Only live frames (`seq > liveSince`) may announce.
- An epoch change emits `.reset` and drops the resume mark.
- Queue commands sent before the socket exists.
- Decode kunai leniently. A new field must not break a known event.
- The first ask wins. Never stack a second card.
- A Desk task goes only to the Desk, in Ask mode. The Desk ask denies itself after 60 s.
- A late reply from an old Shed address must not write state (`generation`).

## Architecture

- Two sources feed one list: kunai (REST poll, then a fleet push) and Shed (REST).
- The poll replaces `sessions`. The controller re-applies live socket state from `socketStates`.
- `apply(_:)` is internal so tests can feed frames. Keep it callable.
- `AgentFleet.isPushing` is true once a stream object exists, not once a frame arrives. It sets the poll cadence.
- Shed agents stay out of `sessions`, because those rows attach to kunai sockets by id.
- Crew sessions also stay out of `sessions`. `CrewAgents` reads `~/.crew/events.jsonl` and the `.crew/crew.json` of each project that the events name, and writes only `~/.crew/STOP`.
- `AgentChangeSet.revert` nil means "not asked". Never show it as safe.

## Do not

- Do not bundle, start or supervise kunai or Shed.
- Do not add `bypassPermissions`. An unknown mode reads as Ask.
- Do not truncate choice options. A card that cannot show them defers to kunai.
- Do not put a spoken prompt into the front app. It goes to a session or the undelivered banner.
- Do not send the master Shed token to a non-loopback Shed. Keep the web view on Shed's origin.
- Do not run blanket `swiftformat`. Do not commit secrets.

## Used by

- `whisper-master/Sources/WhisperMaster/App/`: `AppState` owns the controller (`let agents`). `AppDelegate` starts it and builds the tray rows. `DictationViewModel` handles the agent key.
- `whisper-master/Sources/WhisperMaster/Connectors/Tools/DelegateTools.swift` uses `AgentDesk` and `heldSessions`.
- `whisper-master/Sources/WhisperMaster/UI/Agents/`, `whisper-master/Sources/WhisperMaster/UI/DictationPillContent.swift` and `whisper-master/Sources/WhisperMaster/UI/Settings/AgentSettingsView.swift`.
