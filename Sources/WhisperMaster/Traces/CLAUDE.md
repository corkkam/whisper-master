# Traces (`Sources/WhisperMaster/Traces/`)

Loaded when Claude works under this directory. The root `CLAUDE.md` keeps the
one-paragraph summary and a pointer here.

### What this is, and what it replaced

The **Traces** page (`UI/Settings/TracesSettingsView.swift`, `SettingsSection.traces`)
is the surface that answers "why did it do that". It **replaced the History page**,
which listed final transcripts and nothing else — the least interesting artifact of a
run, and one already sitting in the app you dictated into. `AppState.history` itself
is untouched and still backs the tray's recent-transcripts submenu, which is a
paste-it-again utility and a different feature.

Two tabs, because there are two machines behind them. A dictation is a **text
pipeline** — one input, a fixed chain of passes, one destination. An assistant capture
is a **decision tree** — several tiers, any of which may decline, over tools that may
never have been on the table. One list holding both would have to be either a text
diff or a decision log, and would be a poor version of whichever it wasn't.

### The rules the surface is built on

- **A pass that changed nothing is still listed, and a pass that was switched off says
  so** (`DictationTraceBuilder.skipped`). Omitting either reads as "this step doesn't
  exist" when the truth is "this step ran and had nothing to do" or "you turned this
  off" — opposite answers to the question being asked.
- **`changed` is computed against the text the pass was *handed*, not the raw
  transcript**, and it is **stored, not re-derived at render time**. A trace read back
  months later has to say what it said when it was written.
- **A rejected rewrite is kept** (`PolishTrace.after` survives `.rejected`). "The model
  was never asked", "the model was asked and returned nothing", "the model rewrote it
  and the faithfulness guard threw the rewrite away" and "Smart cleanup is off" are
  four different answers that were **all indistinguishable** before this existed, and
  the third one is the interesting one. Seeing *what* the guard refused is what turns
  "the polish never works" into a report someone can act on.
- **The polish is judged where the model runs and settled where it lands**
  (`PolishTrace.settled(as:reason:)`). An accepted rewrite still fails if the in-place
  edit into the focused field doesn't take, and the call site that knows that is the
  one that restamps the outcome.
- **Every decline carries its reason.** `CommandAgentService.Run` exists because
  `perform`'s `nil` erased which of the four decline rules fired, what tools the model
  had, and what it called. `AgentAttempt` does the same for the view model's tier.
  `DictationViewModel.finish(_:since:)` is the single exit every assistant tier goes
  through, so a route can't be added that quietly records nothing — the discipline
  `SessionAccounting` already enforces for the usage record.
- **`connectorsAllowed` is on the row, not buried in the expansion.** A connected
  mailbox the assistant is walled off from (`connectorAgentEnabled` off) is the
  commonest "the assistant ignores me" cause, and nothing else in the app mentions it
  at the moment it bites. It is **on by default** now — a connector the user
  connected is one they want used — so this row reads false only for someone who
  turned it off on purpose.
- **The tool's real name is shown here.** The notch withholds it deliberately (a bezel
  band is not a debugger); this surface *is* one.
- **The model's own turns are kept, and the tool turns are not** (`AssistantTrace.turns`,
  filled from `AgentOutcome.turns`). A run that spent every iteration on malformed JSON
  journals **no calls at all**, so without this it reads exactly like "the model answered
  without calling a tool" — the wrong failure to go and investigate. Tool turns are
  dropped because their text is already in `calls`, and a trace that keeps every result
  twice is what the clamp exists to prevent. Folded shut in the UI: it is the loop's raw
  transcript, and it is the least readable thing on the page.
- **How a write was permitted is part of what happened** (`ToolCallTrace.authorization`).
  A standing grant, a tap on Once, a tap on Always, a refusal and an unanswered card are
  five different stories, and the row used to tell none of them. A read carries none —
  there was nothing to authorize — so the badge is absent rather than saying so.
- **The approval wait is not the connector's latency** (`ToolCallTrace.approvalMilliseconds`).
  `milliseconds` is measured with the wait taken out, because a write that sat a minute
  on the consent card otherwise reads as a minute of provider latency and sends the
  reader after the wrong thing.

### Where the recording happens

- `DictationViewModel.stopRecording` builds the chain **beside the existing
  `Diagnostics.shared.noteStage` calls**. The two are different instruments — that one
  is a developer-only build that also writes audio and a latency timeline, this one
  ships — and **a new pass must be added to both** or the chains disagree.
- The dictation trace is recorded **before** the paste, because the polish and the
  delivery both land later and need a row to attach to (`attachPolish`,
  `attachDelivery`, keyed by id).
- `CommandToolRouter.journal` records every call — arguments, the connections that
  served it, what came back, how long. It lives there for the same reason `executed`
  does: it is the one point every call funnels through.

### Storage

`UserDefaults`, capped at `TraceStore.limit` (40), text clamped by `TraceText.clamp`
— a trace holds several copies of the same words, and the whole list is read at
launch. **Traces use the synthesized `Codable` and a `try?` load, deliberately unlike
`Note`'s hand-written conformance**: they are disposable and regenerate within minutes
of use, so a decode failure costs nothing. Bump the defaults key rather than growing
an init nobody needs.

**⚠️ A new field on a persisted trace must be optional — a default value is not
enough.** The synthesized `init(from:)` calls `decode`, not `decodeIfPresent`, for any
non-optional property; the default is used by the memberwise init and nowhere else. So
`var approvalMilliseconds: Int = 0` added to `ToolCallTrace` throws
`keyNotFound` on every trace already written, and the `try?` load turns that into a
page that is silently empty until it refills. `ToolCallTrace.approvalMilliseconds`,
`ToolCallTrace.authorization` and `AssistantTrace.turns` are optional for exactly this
reason, and `TraceTests.testATraceWrittenBeforeTheNewFieldsExistedStillDecodes` is the
lock — it decodes the old shape by hand. Device-wide, not per-account: a trace describes *this machine's*
pipeline, and it has to be readable while signed out, since "it stopped working" gets
investigated before anyone thinks to check who they're signed in as.

`TraceStore.seed` is the snapshot renderer's door in and the only writer that isn't
the view model — it deliberately **does not persist**, because the renderer runs
inside a real app process and a seed that persisted would overwrite a real user's
traces with mock ones.

Snapshots: `panel-traces`, `panel-traces-dictation-open`, `panel-traces-assistant-open`
(the collapsed render shows none of the content, so each tab also renders with its
rows open — that is what `initialTab` / `initiallyExpanded` are for). Tests:
`TraceTests`, `ToolJournalTests`.
