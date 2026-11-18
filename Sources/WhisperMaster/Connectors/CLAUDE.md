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
  task (the loop then ends like a spent budget and the words are filed), drops a draft
  waiting on the band, or closes a long answer. With none of these pending it does nothing and returns false, so
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

## Device tools: acting on this Mac (`Tools/DeviceTools.swift`)

Four tools with no connector behind them: `open_app`, `open_url`, `replace_selection`
and `insert_text`. `CommandToolRouter` routes them to `DeviceToolRunner` **before**
the connector branch, so a user with no connection still gets the card.

- **The approval route.** `open_app` and `open_url` go through `WriteAuthorizer` and
  the same card as a connector write, bound to the fixed `DeviceToolCatalog.thisMacID`
  ("This Mac") instead of a `ConnectorInstance`. The taint rule is unchanged: after
  untrusted text a grant does not answer and the card offers no Always. Grants for
  This Mac appear in the Connectors page's revoke list under that label.
- **`open_app` opens only an installed app** (`InstalledApps`, exact name match,
  never fuzzy). Always is offered, and the grant binds to the app's real name.
- **`open_url` shows the card every time.** `PendingApproval.grantable` is false, so
  Always is hidden and no grant is stored even if a caller answers Always. Only
  `http` and `https`, no user name in the link, at most `maxURLLength` (150)
  characters so the whole address fits the card's three wrapped lines
  (`ApprovalCopy.detailLines`). The headline names the host, measured in the title
  font and cut at its **front** so the registrable domain stays visible
  (`DeviceToolCatalog.linkHeadline`); a host whose domain still does not fit is
  refused rather than shown as a misleading prefix. A tainted run refuses a link with
  a query or a fragment before any card, because that is the easiest place for read
  text to ride out. It can also leave in a path or a subdomain: the card on every
  link, with the whole address, is what covers those.
- **The draft tools only stage a draft** (`AgentDraft`, `AppState.agentDraft`). No
  card: the band (`NotchDraftBanner`) is the consent, and its Replace or Insert types
  the text with a real ⌘V and never a Return. The band offers Copy only when:
  - the focus left the key-down app;
  - the draft holds a Cc or Cf character the band cannot show (an escape sequence,
    a bidi override, a zero-width mark), except a tab, and a line break outside a
    terminal;
  - the run read account text (`Taint.outsideSelection`);
  - the run read the selection (`Taint.isSet`) and the draft is an insert, or the
    app is a terminal. **The selection read is exempt only for a Replace outside a
    terminal**, where "make this shorter" types a rewrite back over the text it read;
  - the app is a terminal and the draft has more than one line (trailing newlines are
    removed there first).

  The tap checks again (Accessibility, Secure Keyboard Entry, the front app, and for
  Replace that the selection is unchanged, read off the main actor), and checks the
  front app and Secure Keyboard Entry once more immediately before the paste. Any
  failure copies instead. **A trace keeps a draft's length, never its text**
  (`DeviceToolCatalog.storableArguments`, `storableTurn`): traces persist, and a
  rewrite of the selection slips past the selection's 40-character rule.
- **The fast path** (`Agent/AgentIntentMatcher.swift`): a whole capture of "open
  <installed app>" opens it with no model and no card, like "pause the music". "go
  to <domain>" sends the link to the same card. Legal only inside
  `routeCommandCapture`.
- **No `media_control` tool.** `MediaCommandDetector` already handles transport ahead
  of the model, and a model-route key press during a hold is the bug `Media/CLAUDE.md`
  forbids.

## Verifying

`swift test --filter "DeviceToolRunnerTests|AgentIntentMatcherTests|ApprovalCopyTests"`
for the device tools.
`swift test --filter "MicrosoftConnectorTests|SlackProviderTests|Connector"`. No
test reaches the live Graph or Slack APIs. The first real sign-in after the client
id is set is the end-to-end check.
