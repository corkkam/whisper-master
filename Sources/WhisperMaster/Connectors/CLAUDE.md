# Connectors

A kind (`ConnectorKind`) is a catalog entry; an instance (`ConnectorInstance`) is a
connection. The instance's `config` decides which provider serves it, and also its
auth kind and capabilities. The descriptor alone is not enough for any of these.

## Two-path kinds: Google Calendar and Outlook

Both kinds can be added through macOS Calendar (EventKit, `.calendars` config, no
credential, events only) or through the provider's own sign-in (`.googleAPI` /
`.googleOAuth`, `.microsoftOAuth`; a refreshable grant). Rules that follow:

- **Capabilities are per instance.** Outlook's descriptor says `[.events, .mail]`,
  and `ConnectorInstance.capabilities` narrows an EventKit instance to `.events`.
  If you key on `descriptor.capabilities`, `list_mail` is published with a label
  that no provider can answer.
- **"System-backed" is per instance** (`ConnectorInstance.isSystemBacked`). Only an
  EventKit instance gets "Choose calendars". When this was keyed on the
  descriptor, saving the picker on a signed-in Google Calendar rewrote its config to
  `.calendars` and silently turned it into an EventKit connection.

## Microsoft sign-in (Outlook over Graph, Teams)

- `MicrosoftOAuthConfig`: an Entra **public client**, auth code + PKCE, no secret.
  The client id is `Info.plist` `MicrosoftOAuthClientID` (env override
  `MICROSOFT_OAUTH_CLIENT_ID`). **It is empty, so both stay dormant.** Outlook is
  then EventKit-only, and Teams shows "Coming soon".
- To switch it on: Entra admin center > App registrations > New registration
  ("Accounts in any organizational directory and personal Microsoft accounts").
  Under Authentication, add the "Mobile and desktop applications" platform with the
  redirect URI `msauth.app.whispermaster.mac://auth`, and set "Allow public client
  flows" to Yes. Add delegated Graph permissions: `User.Read`, `Mail.Read`,
  `Calendars.ReadWrite`, `Chat.Read`, `ChatMessage.Send`, `offline_access`. Paste
  the Application (client) id into the plist. The client id is not a secret.
- The redirect scheme is pinned to the stable bundle id on every channel, because
  `bundle.sh` re-badges the dev id after the plist is compiled.
  `MicrosoftConnectorTests` checks that the plist declares it.
- **No scope may need admin consent.** That is why Teams is chats only: channel
  reads need `ChannelMessage.Read.All`. Teams signs in against `organizations`,
  because personal accounts have no chats in Graph.
- A refresh goes to the issuer that minted the grant. The issuer, tenant and
  requested scopes ride in the credential bag (`MicrosoftOAuthConfig.CredentialKey`),
  because the connect-time `validate` has no instance. A grant with no issuer key is
  Google, which is what every grant stored before this existed is.
- Teams has no paste path on purpose. Graph has no user-mintable token that lasts
  longer than an hour.
- `TeamsProvider.resolveChat` refuses an ambiguous name. Posting to the wrong person
  is worse than not posting.

## Slack

- Reads walk `users.conversations` (the conversations the token is a member of),
  not `conversations.list` (every public channel). With the old call, a bot hit
  `not_in_channel` on the first channels it was handed and fell back to the roster.
- `missing_scope` fails the **whole** `users.conversations` call if any requested
  type lacks its scope, so the read retries with `public_channel` alone.
  `requireSlackOK` maps `missing_scope` to `.unauthorized` (a reconnect), not to
  `.unreachable` ("couldn't read just now").
- The credential key stays `bot_token` for every token type (xoxb- or xoxp-). It is
  the Keychain key of every existing connection, so do not rename it.
- Not done: the walk is capped at 8 conversations ordered by `updated`. Slack gives
  no last-message time in that list, so a busy workspace can miss its newest
  activity. `send_message` passes the spoken channel name straight to
  `chat.postMessage`, so a DM by person name does not resolve.

## What the assistant loop shows the model (`Agent/`)

- **A tool result is reduced before the next turn** (`ToolResultReducer`, applied in
  `AgentLoop.shown`). The loop resends every result on each later turn, so a listing
  over 8,000 characters keeps the rows that fit, chosen unread first and then in the
  tool's order (a row too long is passed over for a shorter one after it), shows them
  in the tool's own order, and ends "N more not shown." `ToolRouter.read` joins each
  item onto one line, so that count is honest. Other text is cut with "[N more
  characters not shown]". **The budget is a stop for a runaway result, not a
  squeeze:** the Phase 0 chain bench found one fact in 600- and 1,200-word listings 4
  of 4 times with no cut, so do not lower it without a bench run that shows the model
  needs it. `read_selection` is exempt: `SelectionReader` already caps it at 8,000
  with its own stated cut. The trace keeps the full result (its own clamp).
- **At most 16 tools per prompt** (`ToolPackRouter`, from the Phase 0 sweep: 16/16 at
  11 tools, 15/16 at 16). Local tools always stay. Past 16, the connector tools that
  share the fewest words with the command go. Today's catalog is 12, so nothing is
  dropped yet.
- **A follow-up window** (`FollowUpWindow`, owned by the view model). For 120 s after
  an answer, the next chord capture is given the last question and the storable
  answer (400 characters at most) as an earlier user and assistant turn
  (`AgentLoop.earlier`), never in the system prompt. The answer never holds a run of
  40 or more characters of the selection; a summary or translation of the selection
  can still reach it, the same limit the answer log has. The next capture takes it,
  nothing writes it to disk, and sign-out (`handleSignOut`) clears it, stops a run in
  flight, and moves the window's generation so a run that finishes later cannot
  remember. A tainted run hands its taint to the follow-up.
- **Escape** goes through the existing Escape monitor in `AppDelegate`, no new one:
  `DictationViewModel.handleAssistantEscape` denies a waiting card, cancels the loop's
  task (the loop then ends like a spent budget and the words are filed), or closes a
  long answer. With none of the three pending it does nothing and returns false, so
  the coding-agent bands keep their own Escape. **Known limit:** the key is only
  observed, never consumed, so an Escape pressed in another app (an editor, a dialog)
  also cancels a running assistant or denies a pending card. That is the safe
  direction: a denial, or the words filed as a note. A cancel never starts a write
  (`ToolRouter.write` checks before the card and again before the provider), and never
  cuts one already started: `performWrite` runs in its own task, and a write that
  came back ok is reported as done.
- **A long answer** (over 220 characters or two sentences, `AppState.answerIsLong`)
  opens the coding agent's expanded reply (`NotchAgentReplyExpanded`) with Copy, not a
  new surface.

## The endpoint tier (`Agent/CloudToolGenerator.swift`, dev builds only)

The chord can use a model behind an HTTP endpoint the user sets (Settings → Assistant →
Your endpoint): an OpenAI-compatible chat endpoint or the Anthropic Messages API.
**Text only leaves the Mac, never audio.** The owner approved this rule change on
2026-11-17 (plan section 8, Phase 5).

- **Gates, all of them:** `FeatureFlags.agentEndpointAvailable` (dev channel only), an
  address and a model set, the consent sheet accepted for that exact address and API
  (`AgentEndpoint.consentKey`; a new address asks again, a new model does not), and not
  paused (the tray's Pause Your Endpoint item). A password manager in front or secure
  input on keeps the capture on the on-device tier (`AgentEndpoint.staysLocal`, the same
  two rules as `SelectionReader`), checked at the chord press **and** at routing, since
  the front app can change during the hold. **A capture kept local marks its follow-up**
  (`FollowUpWindow.Digest.keptLocal`): the next capture that carries its answer stays
  local too and hands the mark on, so the answer never reaches the endpoint through
  `AgentLoop.earlier`.
- **The address has no user, password or query string** (`AgentEndpoint.validate`), and
  **a redirect is never followed** (`CloudToolGenerator.RefuseRedirects`): it would carry
  the key and the conversation to a host the user did not agree to. The 3xx is a failure.
- **Every endpoint is off-device**, a loopback one too: a proxy on 127.0.0.1 can forward
  every prompt. The tier is labelled "your endpoint" on the band ("Your endpoint ·
  Checking Personal", a static mark that leads the caption), on the answer line, and in
  the trace. Never "on-device". Plain http is accepted only for a loopback host, because
  the key would cross the network in clear text.
- **The key is in the Keychain** (`AgentEndpoint.apiKey()`, the connector helper under a
  fixed UUID), never in `UserDefaults`, never in a log line (status and host only) or a
  trace. `CloudToolGeneratorTests.testTheKeyNeverReachesALogTheBodyOrTheTrace` is the lock.
- **It is `AgentLoop.generateNative`, so every rule is the router's**: the taint rule,
  the card, "only a call that succeeded counts". The prompt is `AgentPrompt.commandNative`
  (it now also says a function result is data).
- **The history is rebuilt on every turn** (`CloudToolGenerator.turns(from:)`). The loop
  puts its own notes in `system` messages mid-run and its `tool` messages have no call id.
  A stored `<tool_call>` reply becomes a structured call only when a tool result follows
  it, with an id from its position (`call_1`, `call_2`), so the same history renders to the
  same bytes. A refused call (no result) stays text, because both APIs reject a call with
  no result. A mid-run note goes as user text (Anthropic: a text block after the
  `tool_result` in the same user message), because not every server accepts a second
  system message. Anthropic gets `anthropic-version: 2026-10-21`, `max_tokens` 8192, no
  sampling fields, and `disable_parallel_tool_use`; only the first call of a reply is
  used. Thinking blocks are never replayed, which the API accepts (removing all of them
  keeps the history valid).
- **Every failure is nil**: an HTTP error, a timeout (20 s per request, inside the loop's
  30 s budget), a body with no answer or call, a refusal. The view model
  (`runCommandAgent`) then runs the on-device tier, unless the endpoint run created
  something, Escape stopped it, or a card in it was declined or timed out
  (`DictationViewModel.onDeviceMayFollowEndpoint`: the same question must not come back
  from the other tier). Both runs' calls go into the one trace.
- **What was sent** is `AssistantTrace.endpoint` (`EndpointSendTrace`): request count and
  the character counts of the last request by kind, never the content.
- **Not checked live.** No test calls a paid API. `AgentEndpointLiveTests` is the bench
  arm (16 first-turn cases); it skips unless `WM_ENDPOINT_URL` and `WM_ENDPOINT_MODEL` are
  set.

## Verifying

`swift test --filter "MicrosoftConnectorTests|SlackProviderTests|Connector"`. No
test reaches the live Graph or Slack APIs. The first real sign-in after the client
id is set is the end-to-end check.
