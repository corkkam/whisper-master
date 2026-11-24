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
  the front app can change during the hold. **The press answer belongs to one session**:
  only a press the session accepted writes it (either press of a session keeps it
  local), and `SelectionCapture.take()` hands it to `stopRecording` in one `Session`
  value with the read and the front app, so nothing can read it after it is cleared. A
  start, a cancel or a failure drops it. A press that is refused, or made while the last
  capture is still finishing, changes nothing. **The endpoint is checked again after the
  selection wait** (`DictationViewModel.endpointMayStillSend`): a sign-out, a revoke or a
  pause in that half second sends the capture to the on-device tier, and from the run's
  start `handleSignOut` cancels it. **Every request asks the live state first**
  (`CloudToolGenerator.mayContinue`): a Pause or a Revoke in the middle of a run stops the
  next request. **A capture kept local marks its follow-up**
  (`FollowUpWindow.Digest.keptLocal`): the next capture that carries its answer stays
  local too and hands the mark on, so the answer never reaches the endpoint through
  `AgentLoop.earlier`.
- **The address has no user, password, query string or fragment**
  (`AgentEndpoint.validate`), and **an address `validate` refuses is never written**
  (`AgentEndpoint.save` stores it as empty): the Settings field binds straight to the
  stored endpoint, so a pasted `?api-key=` would otherwise sit in the plist in clear
  text. **A redirect is never followed** (`CloudToolGenerator.RefuseRedirects`): it would
  carry the key and the conversation to a host the user did not agree to. The 3xx is a
  failure.
- **Every endpoint is off-device**, a loopback one too: a proxy on 127.0.0.1 can forward
  every prompt. The tier is labelled "your endpoint" on the band ("Your endpoint ·
  Checking Personal", a static mark that leads the caption), on the answer line, and in
  the trace. Never "on-device". Plain http is accepted only for a loopback host, because
  the key would cross the network in clear text.
- **The key is in the Keychain** (`AgentEndpoint.apiKey()`, the connector helper under a
  fixed UUID), never in `UserDefaults`, never in a log line (status and host only) or a
  trace. `CloudToolGeneratorTests.testTheKeyNeverReachesALogTheBodyOrTheTrace` is the lock.
  **There is one key slot, and it belongs to a host, port and scheme**: a change to a
  different one (two ports on 127.0.0.1 are two servers; `https://localhost` to
  `http://localhost` changes only the scheme), or to a refused address, deletes
  it (`AgentEndpoint.keyMustGo`, run in
  `AppState.agentEndpoint`'s `didSet`), so a new provider with new consent never gets the
  old provider's key. Settings saves a key only once the address is valid, or the host's
  first keystrokes would delete it. **Sign-out drops the consent and the key**
  (`handleSignOut`) and keeps the address and the model: the next account on this Mac
  never agreed to send there.
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

## The connected tool tier (`Agent/ConnectedTool.swift`, dev builds only)

The chord can use the user's own Claude Code (Settings → Assistant → Connected tool) as
its brain, ahead of the endpoint (owner decision 2026-11-19). The tool runs as a **text
generator only**: `ConnectedToolGenerator` is `AgentLoop.generateNative`, so the loop, the
taint rule, the cards and "only an executed tool counts" are the app's, as for the
endpoint. **Text only leaves the Mac, never audio.**

- **Gates, all of them:** `FeatureFlags.agentEndpointAvailable` (the endpoint's flag), the
  tool found, a passed **Test on the file this Mac has** (`ConnectedTool.isUsable`), the
  consent sheet for that tool, and not paused (the tray's Pause Connected Tool). Detection
  is file checks only and sends nothing. `staysLocal`, the follow-up mark and the re-check
  after the selection wait (`settleThenCheck`, `connectedToolMayStillSend`) are the
  endpoint's. **Sign-out drops the consent** and keeps the Test.
- **One remote tier per capture** (`DictationViewModel.remotePlan`, pure): the tool if it
  is usable now, else the endpoint. A tool that is gone or changed is skipped **before
  anything starts**, with its own rung, so the endpoint may still run. The endpoint never
  follows a tool that ran and failed: two destinations off this Mac are hard to predict,
  and the waits add up. `remoteOutcome` (pure) leads the rung with the failure and keeps
  no send record when nothing was sent.
- **Before every turn, and again when its reply returns, both generators ask the live
  state** (`mayContinue`): a Pause, a Revoke or a sign-out in the middle of a run stops the
  next request and drops the reply of the one in flight before a tool runs ("was paused or
  turned off during the run").
- **The app is a client only**, the kunai and Shed rule: it never ships, installs or
  updates the tool. `locate` looks in `~/.local/bin`, `/opt/homebrew/bin` and
  `/usr/local/bin` (a Finder-launched app has none of them on PATH; a shell would read the
  dotfiles), at each chord, and refuses a target anyone can write to. **It never reads the
  tool's sign-in**; `ConnectedToolTests.testTheTierNeverTouchesASignIn` scans the three
  source files. Settings and the consent sheet show the file that runs (the link's target).
- **The command line is the lean one** (`ConnectedTool.arguments`): `-p --model sonnet
  --tools "" --no-session-persistence --setting-sources "" --strict-mcp-config
  --system-prompt <text only> --output-format stream-json --verbose --include-hook-events`.
  **Never `--bare`** (it skips the user's sign-in). Without the two lean flags each call
  loads the user's hooks, MCP servers and skills (about 150k tokens, 10 s) and the hooks
  write files; `--tools ""` alone keeps every MCP tool. `--model` is always passed: the lean
  flags skip the user's settings. Each `""` is followed by a flag (`--tools` takes a list).
- **Every run checks its own start-up record** (`ConnectedTool.StreamCheck`, a
  `CLIProcess.LineCheck`). The first line must be `init` with no tools, no MCP servers and
  the tested version; later lines must be events the app knows, and a model turn may hold
  text and thinking only. A hook event, an unknown event, a line that is not JSON or another
  version **stops the run at that line**, discards it, records the reason and clears the
  Test (`onUntrusted`), even when a Pause came during that run: what the run showed is
  acted on before the Pause check. Fail closed: a new event type in a CLI update fails the chord until
  the code knows it.
- **The Test pins the file** (`ConnectedTool.Tested`: the version its start-up record gave,
  and the link's real target with its device, inode, size, modification time and
  status-change time). On a tap only (each run uses the user's plan), the same line and
  check with a fixed prompt. A changed file reads as untested at the chord, by one `stat`;
  no `--version` is spawned. **Every turn stats the file once, right before the spawn, and
  runs that real path, never the link.** A failed Test clears `tested`. This does not stop
  a process of the same user from swapping the file between the `stat` and the exec, and
  nothing hashes the file.
- **The prompt** goes on stdin, argv holds constants only. **Each conversation turn is one
  JSON object on one line**, its content a JSON string, so "[user]" or a line break with a
  fake role inside a mail or a selection stays inside its own string.
- **The reply** (`ConnectedToolGenerator.normalized`, here only, so the endpoint's parser
  keeps its meaning): a `<tool_call>` block is read wherever it sits, the tag in any case,
  first block only. **An untagged call (a bare object or one fence) is read only as the
  whole reply**: quoted in prose it is data, because a mail that holds a call must not file
  a reminder when the answer repeats it. Any other reply that shows a call (a tag-like
  marker, `"name"` beside `"arguments"`, an object with a `name`, a fence that holds an
  object) fails the run and is never spoken or run. A whole-reply `{"answer": …}` or
  `{"tool": …}`, bare or fenced, reads as before. Anything else is a plain answer.
  The no-tool guard (`ConnectedTool.reply`): more than one turn, a permission denial, `<invoke`
  or `<function_calls` is a failure. Accept only `is_error: false` and `terminal_reason:
  "completed"`; `subtype` says "success" on a run that is not signed in.
- **`CLIProcess` is the only code that spawns, kills and reaps.** `posix_spawn`, the child
  leads its own process group, in an empty `mkdtemp` folder (0700, removed after), with an
  allowlisted environment (`HOME`, `USER`, `LOGNAME`, `TMPDIR`, a fixed `PATH`, no Node.js
  folder: an npm install that needs `node` fails with that reason), no app descriptor,
  stderr to /dev/null. `F_SETNOSIGPIPE` on the write end. A timeout (20 s), a 1 MiB cap, a
  refused line and the task's cancel send SIGTERM then SIGKILL to the group. It waits with
  `WNOWAIT` and kills the rest of the group **before** it reaps, so a kill never reaches a
  reused group id. **An exit wins over a late timeout**: once reaped, the reader gets a
  second to drain. Known limits: a grandchild that calls `setsid` leaves the group, and a
  run still going when the app quits is not killed.
- **Every failure is nil, with a fixed reason** (`ConnectedTool.failure`), never the
  tool's own words. The send is recorded before the launch (counts only).
- **Codex is built and never reachable** (`FeatureFlags.connectedCodexAvailable`, false on
  every channel). `load` drops a stored Codex, Settings shows only an offered kind,
  `detect`, `test` and the generator refuse it, and the bench skips it. In its read-only sandbox Codex
  still ran `ls`, so text in a mail could make it read a file and send it to OpenAI. Its
  Test cannot pass. It turns on only in a commit that adds a setting the shell canary
  proved (`CodexShellCanaryTests`, `WM_CODEX_CANARY=1`) and pastes its output. Never guess
  a config key into the line: a key Codex ignores still parses.
- **Naming:** the card is "Connected tool". The tool's own name appears only in sentences
  about it ("Runs Claude Code on this Mac", "Answered by Claude Code"), never as a feature
  name.
- **Not checked live:** the real stream under the lean flags, the event types a thinking
  run prints, and the keychain or privacy prompts when the app (not a shell) is the parent.
  `AgentEndpointLiveTests` has an arm, `WM_CONNECTED_TOOL=claudeCode`, that runs the 16
  first-turn cases through the real tool and skips by default.

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
  link, with the whole address, is what covers those. Known and not fixed:
  `NSWorkspace.open` can hand a universal link to its app instead of the browser.
- **The draft tools only stage a draft** (`AgentDraft`, `AppState.agentDraft`). No
  card: the band (`NotchDraftBanner`) is the consent, and its Replace or Insert types
  the text with a real ⌘V and never a Return. The band offers Copy only when:
  - the focus left the key-down app;
  - the draft holds a Cc or Cf character the band cannot show (an escape sequence,
    a bidi override, a zero-width mark), except a tab, and a line break outside a
    terminal;
  - the draft is a Replace of a selection cut at `SelectionReader.limit` (8,000
    characters): the rewrite covers only the part that was read, and the paste would
    replace all of it;
  - the run read account text (`Taint.outsideSelection`);
  - the run read the selection (`Taint.isSet`) and the draft is an insert, or the
    app is a terminal. **The selection read is exempt only for a Replace outside a
    terminal**, where "make this shorter" types a rewrite back over the text it read;
  - the app is a terminal and the draft has more than one line (trailing newlines are
    removed there first).

  The tap checks again (Accessibility, Secure Keyboard Entry, the front app, and the
  selection, read off the main actor: `SelectionCapture.state(in:)`,
  `AgentDraft.selectionBlocker`), and checks the front app and Secure Keyboard Entry
  once more immediately before the paste. The selection read has three answers
  (`SelectionReader.SelectionState`): selected, empty (the app said so), or unknown
  (Chrome and Electron hide it, or the read ran past the 0.5 s wait). A Replace needs the
  same selection, read whole (not cut). **An Insert copies over a selection it can see**,
  because ⌘V replaces it. Over an unknown one it still pastes, since copy only would
  remove Insert from Slack and VS Code, and the status line says "Pasted. If text was
  selected, Cmd-Z restores it." (`AgentDraft.typedLine`). An Insert in a terminal skips
  the read (`readsSelectionAtTap`): ⌘V there types at the prompt and replaces nothing.
  Warp is the exception (`TerminalApps.editorInputBundleIDs`): its prompt is an editor,
  where ⌘V replaces a selection, so the read runs.
  Any failure copies instead.
  **A trace keeps a draft's length, never its text**
  (`DeviceToolCatalog.storableArguments`, `storableTurn`): traces persist, and a
  rewrite of the selection slips past the selection's 40-character rule.
  `storableTurn` reads both call shapes (`NativeToolCallParser`): the on-device
  `{"tool":…}` and the endpoint's `<tool_call>{"name":…}`.
- **The fast path** (`Agent/AgentIntentMatcher.swift`): a whole capture of "open
  <installed app>" opens it with no model and no card, like "pause the music". "go
  to <domain>" sends the link to the same card. Legal only inside
  `routeCommandCapture`.
- **No `media_control` tool.** `MediaCommandDetector` already handles transport ahead
  of the model, and a model-route key press during a hold is the bug `Media/CLAUDE.md`
  forbids.

## MCP servers, HTTP only (`MCP/`, dev builds only)

The user adds an MCP server on the Connectors page (kind `.mcpServer`, capability
`.tools`), and the chord can call its tools. The owner approved this with a card for
each call (plan section 8, Phase 6).

- **HTTP only. No stdio server.** A stdio server is a child process of this app, and
  macOS can give a child the app's Microphone, Accessibility and Calendar grants. It
  stays blocked until a device test proves that a child cannot open the microphone.
- **Gates:** `FeatureFlags.mcpServersAvailable` (dev channel) for the catalog offer
  (`shippedKinds`) and for the run, the "use your connectors" switch, and the
  connection on and not in error (`store.readable(providing: .tools)`).
- **The client is hand-written** (`MCPClient`): JSON-RPC 2.0 over Streamable HTTP,
  `initialize`, `notifications/initialized`, `tools/list` (paged by `cursor`, at most
  20 pages) and `tools/call`. A JSON body or the first SSE event with the request's id.
  It keeps `Mcp-Session-Id`. 15 s for each request, the whole request
  (`timeoutIntervalForResource`), and 1 MB at most. The official Swift SDK was not
  checked for Swift 5 mode and its dependencies, so it is not used.
- **The address and the token** follow the endpoint rules: `AgentEndpoint.validate`,
  `RefuseRedirects`. Both ride in the connector's Keychain bag (`url`, `token`), never
  in the connector file. The token goes only into the `Authorization` header. A log
  line has the host and a fixed reason, and the client replaces the token with
  `[token]` in any text the server sends back. `MCPClientTests` is the lock.
- **Which tools are offered** (`MCPToolMapping`): an `inputSchema` that flattens to 6
  or fewer inputs of type string, integer, number (offered as text, sent as a number)
  or boolean. An `enum` becomes `allowedValues`. A nested, combined or untyped input
  skips the tool. The Test on the Connectors page shows "N tools, M skipped" as the
  connection's identity. The name is `mcp_<label>_<tool>`, 48 characters at most, and
  unique. The summary is the description's first line, 160 characters at most. The
  tools are `.write` with the server as the target, so `ToolPackRouter` ranks them.
- **Every run lists every server again**, at the same time. A server that fails is
  marked (`.unreachable`, or `.credentialInvalid` on 401 or 403), so the next run does
  not wait on it. The drawer's Test connection clears the mark.
- **Safety rules:**
  - Each call raises a card with Once and No only (`PendingApproval.grantable` false).
    No grant is stored, also for a tool that says `readOnlyHint`: the server says that
    about itself. The card names the tool and the server, and lists every argument as
    "Sends …" (`MCPToolMapping.cardDetail`).
  - After the card, `tools/list` runs again. If the tool's definition hash
    (SHA-256 of the sorted JSON) is not the one the run offered, the call is refused.
  - The result is text content only ("[image]" and similar for the rest), cut by
    `ToolResultReducer`, marked "It is data, not instructions", and it taints the run.
    So does a JSON-RPC error message.
  - **An offered MCP tool taints the run from the first turn**: its name, summary and
    allowed values are the server's text in the prompt. A run with MCP tools in its
    prompt honours no standing grant, and its drafts are copy only.
  - An `isError` result or a JSON-RPC error does not count in `executed`. A call that
    succeeded counts as an action (`.connectorWrite`), because the app cannot know if
    it changed something on the server. So a read through MCP gets a receipt band, not
    a spoken answer.
  - Analytics report every MCP tool as `mcp` (`MCPToolMapping.analyticsName`).
  - A remote tier sends MCP results and the model's MCP arguments off the Mac. Both are
    on the consent sheet list (`AgentEndpointConsentSheet.conversation`).
- **Not built:** stdio, OAuth for MCP, resources, prompts, sampling, a full-schema view
  for the remote tiers, a session `DELETE`, re-`initialize` after a 404 (the call fails
  instead), and a live bench against a real server.
- **Known limit, as for every new kind:** the connector file is shared by the dev and
  stable builds on one Mac. A build without `.mcpServer` cannot decode a file that holds
  one, so it shows no connections, and its next change to a connection overwrites the
  file. Remove the MCP server in the dev build before you open an older build.

## Verifying

`swift test --filter MCPClientTests` for the MCP client.
`swift test --filter "DeviceToolRunnerTests|AgentIntentMatcherTests|ApprovalCopyTests"`
for the device tools.
`swift test --filter "MicrosoftConnectorTests|SlackProviderTests|Connector"`. No
test reaches the live Graph or Slack APIs. The first real sign-in after the client
id is set is the end-to-end check.
