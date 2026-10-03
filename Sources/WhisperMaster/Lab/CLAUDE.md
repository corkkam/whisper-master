# Model Lab (`Sources/WhisperMaster/Lab/`)

Loaded when Claude works under this directory. The dev build's bench: install
several open-source MLX models, run the app's real suites against each one, and
compare them on quality, latency and memory.

### What it is for

One question — **is this candidate better than what ships** — and the page is
shaped around it. `Compare` (baseline against candidate, case by case, with the
words) is the default half; the ranked table is the other tab; the history rail
is the third piece, because a bench nobody can look back at cannot say whether
last month's change held.

### The gate, and why it is repeated

`FeatureFlags.modelLabAvailable` is `ReleaseChannel.current == .dev`, which also
covers a bare `swift build` run and the headless snapshot renderer. The page is
**absent** on other channels rather than "Coming soon" (`SettingsSection.isListed`):
it is not a roadmap entry, it is a bench for whoever is building the app.

**`LabModelOverride` repeats that gate, and that repetition is the load-bearing
one.** The UI being unreachable is a convenience; the model not loading is the
guarantee. It is fenced three ways: refused on any channel but `dev`, validated
against the filesystem on every read (a deleted model falls back to the shipped
one instead of wedging cleanup on a missing directory), and it stores a
**catalogue id**, never a path. It is read from `CleanupModel.directory` and
`CleanupModel.General.directory` — deliberately low, so the installer's
`isInstalled` check, the manager's retry loop and the Settings hint all get one
consistent answer to "which model is this". `CleanupModel.shippedDirectory` is
where the installer still writes.

### Nothing is duplicated, and that is deliberate

Every number the lab reports comes from the code that ships, not from a copy:

- **Generation** — `MlxCleanupService.cleanMeasured` / `generateWithToolsMeasured`
  are the same path `clean` / `generateWithTools` take, returning the
  `GenerationCost` the dictation path throws away. A bench that re-implemented
  generation to measure it would be measuring something else.
- **The deterministic passes** — `LabDeterministicPipeline.run` (in
  `LabBenchRunner.swift`), which `EvalRunner` now calls too. The ordering rule it
  encodes (collapse self-corrections *before* ITN) only holds while every copy
  agrees, and there were two copies.
- **Scoring** — `EvalScoreKit`'s `Scorer`, `EvalCase` and `WER`, the eval's own
  mechanical arbiter. SwiftPM builds it as a module (`Package.swift`) and the Lab
  sources import it under `#if SWIFT_PACKAGE`; the Xcode app target compiles the
  same files in-target (`project.yml` → `eval/text-cleanup/EvalScore`), where
  there is nothing to import. **Keep both in step when adding a file there.**
- **The tool set and the tool cases** — `LabToolBench` and
  `LabSuiteLoader.toolCases`, shared with `AgentToolEval`. Two benches drifting
  apart on which commands they ask about would make their numbers incomparable,
  which is the only reason to have two.
- **The guard** — the real `CleanupFaithfulnessGuard`, with the target's own
  `allowsRephrase`.

**The subjective quality call is still Claude Code's, outside the app.** The lab
scores keyword rules, WER and tool correctness, and exports a run in exactly the
`results.json` shape `eval-score` and the run-history dashboard already read
(`LabRunExport`), so nothing downstream had to change.

### The case files are found, not bundled

`LabPaths` resolves the checkout: `WM_LAB_REPO`, then a folder the user picked
(`WhisperMaster.lab.repoPath.v1`), then the repo this binary was compiled from
(`#filePath`). A candidate is only accepted when `cases.jsonl` is really in it, so
a wrong folder says so when it is chosen rather than at the start of a 15 minute
run. Bundling the suites would mean two versions of every case and a build step to
keep them equal; this is a dev surface on the machine that built it.

### Any Hugging Face model, by id

The catalogue is `LabCatalog.builtIn`; anything else is typed into the rail's
"Add from Hugging Face" field (a bare `owner/name` or a pasted URL) and saved in
`LabCustomModels` (`WhisperMaster.lab.customModels.v1`), with the id `hf:<repo
lowercased>` so it can never collide with a built-in one.

- **The repo is checked when it is added, not when the run starts.**
  `LabHuggingFace.check` reads `GET /api/models/<id>?blobs=true` and refuses a
  repo that is missing, gated, has no `config.json` / `tokenizer.json` /
  `.safetensors`, has no chat template, or names a `model_type` the pinned
  MLXLLM cannot build. It needs `tokenizer.json` specifically because the
  download fetches `*.json`, `*.safetensors` and `*.jinja`, never
  `tokenizer.model`.
- **⚠️ The chat template is often in `chat_template.jinja`, not in the API.**
  Every Qwen3 2507 build and SmolLM3 keep it there, so the API's `config`
  carries none. The check fetches that file, and `LabHuggingFace.download` adds
  `*.jinja` to the fetch because `MLXLMCommon.downloadModel` does not: a 2507
  model fetched by MLX alone arrives with no template and fails every prompt. Hugging Face answers **401, not 404**, for a repo
  that does not exist when you are not logged in.
- **Supported architectures are asked of `LLMTypeRegistry`, never copied.** The
  registry has no lookup, so `isSupportedModelType` builds from a config file that
  does not exist: an unknown type throws `unsupportedModelType` first. Bumping
  mlx-swift-examples widens the list with no edit here.
- **The tool suite is offered only when the chat template takes `tools`.**
  Same reason a normalizer is kept out of it.
- **A saved repo id is re-validated on every read.** It becomes a directory under
  the Hugging Face cache, and the slot override can point the shipped cleanup path
  at that directory, so `..` in a hand-edited defaults value must not become a path
  out of the cache. This is what keeps `LabModelOverride`'s "never a path" fence
  true for added models.
- **The runner downloads before it loads.** The load is capped at 60 s
  (`MlxCleanupService.loadTimeoutSeconds`), and a load that had to fetch first
  spent that minute on the network, so anything much over a gigabyte failed as
  "load failed" without reaching the GPU. This applied to the built-in candidates
  too. Progress goes to the run log every tenth (`LabDownloadTenths`).
- **⚠️ The first download after launch can be refused as "offline".** The hub
  client creates its network monitor on that call and reads "not connected"
  until `NWPathMonitor` reports. `LabHuggingFace.download` retries
  `offlineModeError` twice. The client also counts Low Data Mode and a phone
  hotspot as offline, which no retry fixes, and the error says so.
- **Remove takes the files with it.** An added model off the list is a download
  nobody can reach from the page. Saved runs keep their results under its name.
- Live check of the API shape: `LAB_HF_LIVE=1 swift test --filter LabHuggingFaceTests`
  (skipped otherwise).

### Reasoning models

A model that thinks before it answers is benched on the **tool suite only**, as a
row of its own, so it can sit beside the shipped assistant in one run.

- **`LabReasoning` is read off the chat template.** `enable_thinking` anywhere →
  `.optional` (Qwen3 hybrids, SmolLM3). `<think>` opened after the *last*
  `add_generation_prompt` → `.always` (Qwen3 Thinking-2507, the R1 distills).
  Only the tail counts: the shipped Instruct-2507 template names `<think>` in its
  body to strip it from earlier turns, and is not a reasoning model.
- **A hybrid gets two rows over one download**: the plain row, and
  `<id>+reasoning` (`LabModel.reasoningVariant`, assistant-only, `thinks`). An
  `.always` model is one row, assistant-only, and an added one that also takes no
  tools is refused: no suite here could measure it.
- **The reasoning budget is the lab's alone.** `generateWithToolsMeasured(thinking:)`
  renders with `enable_thinking: true` and gets `reasoningMaxTokens` (2048) and
  `reasoningTimeoutSeconds` (60 s). Every shipped path still renders with
  `enable_thinking: false` on 512 tokens / 12 s, which cut every reasoning model
  off before it answered.
- **A model out of budget with no `</think>` scores no answer, never its
  reasoning.** Its reasoning can name the tool it is weighing, and handing that to
  the parser would pass a model that never answered. The case says "still
  reasoning when the budget ran out".
- **⚠️ A reasoning row can never take a shipped slot.** `LabController.canUse`
  refuses it and `LabModelOverride.directory` repeats the refusal, because the
  shipped paths cannot reason and an `.always` model would time out on every turn
  of a dev build's assistant. Making the assistant reason is a change to
  `CommandAgentService`'s budget and prompt, not a lab toggle.
- Reasoning tokens per case are kept (`LabCaseResult.reasoningTokens`) and the
  median goes in the run log. Latency already carries the cost in time.
- **Measured 2026-10-04 (M5, 24 GB, tool suite, 16 cases, run 5).** The shipped
  Qwen3-4B-Instruct-2507 scored 16/16 at 3.9 s p50. Qwen3-4B-Thinking-2507 scored
  15/16 at 10.7 s p50 (64 s p95, 328 reasoning tokens median); Qwen3-1.7B with
  reasoning scored 15/16 at 6.4 s p50. Each miss was a case still reasoning at the
  budget. **On first-turn tool choice, reasoning buys nothing and costs 2.7x the
  latency**, so do not re-run this to decide that question. Where reasoning could
  earn its cost is the turn that reads a tool result, which this suite does not
  ask; that needs `AgentToolEval`'s grounding case, not a bigger budget here.

### Measurement rules

- **One model resident at a time.** Two models loaded together share one GPU
  allocator, so neither one's peak is its own and the comparison silently becomes
  a comparison of load order. Each model is loaded, warmed, run, released, and
  MLX's buffer pool cleared before the next — which is why a four-model run pays
  four load times.
- **Peak GPU is a delta over the pre-load baseline, not MLX's raw high-water
  mark.** MLX accounts for the whole process, and the shipped cleanup model is
  usually already resident (Smart cleanup on), so the raw figure would charge its
  335 MB to every candidate — by a different amount depending on what else
  happened to be loaded. The run bar says so when that is the case.
- **GPU memory and process footprint are both reported, because they answer
  different questions.** `MLX.GPU.snapshot()` is what the model costs;
  `phys_footprint` is what the app costs the machine (Activity Monitor's number),
  and includes the ASR models and the UI. Either one alone misleads.
- **Memory is sampled at case boundaries, not on a timer.** A timer racing an MLX
  generation adds Metal traffic to the thing being measured; the peak comes from
  MLX's own high-water mark, so nothing is missed between samples.
- **ASR runs once per audio case, not once per model.** The recording does not
  change between models; only the cleanup does.
- **A suite that cannot load fails loudly.** A bench that quietly ran 40 of 92
  cases and reported 100% is worse than one that refuses to start.

### Suites

`cleanup` and `polish` (the same `cases.jsonl` through the two shipped prompts),
`destinations` (`flow-cases.jsonl`, one row per declared target — the target joins
the id, or three rows collide), `tools` (16 spoken commands, native tool schemas,
first turn only, **assistant-role models only**), and `audio` (the committed
recordings through the real streaming transcriber, scored on WER).

### Testing

`ModelLabTests` covers the pure half — catalogue, paths, loader, statistics,
comparison, run store, export shape, and the override's fences. **MLX cannot run
under `swift test`**, which is why the decisions live in pure types and only
generation sits behind the actor; `LabMemorySource` is the seam for the same
reason. The page renders headlessly as `panel-lab.png` and
`panel-lab-leaderboard.png` from mock data seeded by `SnapshotMode`
(`seedForSnapshot` never writes to disk).
