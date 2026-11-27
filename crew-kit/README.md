# Crew

Crew is a per-project agent team. One lead agent takes every task. It plans the work, asks a few persona agents for an opinion at a gate, gives code to the component agent that owns the folder, verifies the result and writes the record. Hooks enforce the rules, and a ledger enforces the budget.

**Status: dev only.** The kit is for the developers of this repo. It is not supported for anyone else, and its commands and files can change without notice.

## Rules

- Each user signs in to Claude with their own plan or their own API key. The kit does not supply an account.
- The kit never reads Claude or Codex credentials. It never passes `--bare`, so your own hooks and settings always run.
- No level of autonomy merges, releases or deploys. Every result is a branch and a pull request that a person reviews.
- Python 3.9 or later, standard library only.

## Install

```sh
python3 crew-kit/bin/crew install          # copies the kit to ~/.crew/kit/0.1.0/ and writes ~/.crew/bin/crew
export PATH="$HOME/.crew/bin:$PATH"        # add this line to your shell profile
crew --version                             # crew 0.1.0
```

`crew install --force` replaces an installed copy of the same version. The hooks call `~/.crew/bin/crew`, so a removed worktree does not break them.

## Set up a project

Run this in the project root:

```sh
crew init --lead-name Atlas --dry-run      # list the files, write nothing
crew init --lead-name Atlas
crew add-component input --dir Sources/App/Input
crew doctor
```

`crew init` writes `.crew/crew.json`, `.crew/STATE.md`, `.crew/BACKLOG.md`, the agent files in `.claude/agents/`, the skills `crew-huddle` and `crew-retro`, the crew block in `AGENTS.md`, and stubs of `DECISIONS.md`, `ARCHITECTURE.md` and `memory/MEMORY.md`. It merges the crew hooks into `.claude/settings.json` and keeps your own hooks. It scans the folders for default gate rules: `ui`, `web`, `app`, `components` and `copy` give `user-facing`, `auth` and `secrets` give `security`, and `scripts`, `release` and `.github` give `release`.

The lead id is always `lead`. The name (`Atlas`) is a display name that you can change in `crew.json`. New crews start at autonomy level L2: the lead plans and huddles, then stops for your approval. Change the level with `crew autonomy <L0..L5>`.

Other flags: `--no-agents-block` writes the block to `.crew/agents-block.pending.md` and leaves `AGENTS.md` unchanged. `--force` rewrites only the agent files, the skills and the crew block. A second `crew init` without `--force` exits 2 and changes nothing. `crew init` refuses a symlinked `.claude/agents` folder.

## Daily use

```sh
crew run "Add a regression test for the double-press hotkey bug"
crew run --task-id <task_id> --approved "<task>"   # after a needs_approval stop
claude --agent lead                                # an interactive session with the lead
crew status
crew budget
crew stop                                          # stop every crew run in this project
```

You can dictate the task. Hold the Typing.sucks key in the terminal, say the task, and let go. The words go into the prompt like typed text.

## Commands

| Command | What it does |
|---|---|
| `crew install [--force]` | Copy the kit to `~/.crew/kit/<version>/` and write the shim |
| `crew init` | Set up Crew in this project |
| `crew add-component ID --dir PATH` | Add the component agent `c-ID`, its `INTERFACE.md` and its `DECISIONS.md` |
| `crew add-persona ID --name NAME --consult-on TAGS` | Add a persona agent |
| `crew doctor` | Check the crew files, hooks and limits. Exit 7 on an error |
| `crew route --type T --paths P --tags T` | Show who writes, who joins the huddle and why |
| `crew run "TASK"` | Run the lead on one task in a fresh context |
| `crew loop` | Run the lead in a loop (levels L4 and L5 only) |
| `crew autonomy LEVEL [--days N]` | Set the autonomy level. Only a person can run it |
| `crew budget`, `crew status`, `crew memory AGENT` | Show spend and windows, agent activity, and the files an agent loads |
| `crew check-public --text-file F` | Exit 7 when the text has a word that must not go in a public repo |
| `crew stop`, `crew resume` | Set or clear the STOP file |
| `crew hook event`, `crew hook guard`, `crew hook session-start` | Hook commands. The hooks call them |

## Add a persona

A custom persona needs a lens of 3 to 6 lines. Write each line on its own line, or separate them with `\n`.

```sh
crew add-persona security-reviewer --name Sentry --consult-on security,privacy \
  --lens 'Which secret, token or permission does this change touch?\nCan a crew agent or a user reach data that it must not?\nWhich test proves the guard still denies it?'

crew add-persona support --name Sky --consult-on user-facing,release \
  --lens 'Which question will users ask support after this ships?\nWhich error message will they see, and does it say what to do?\nWhat must the release notes say?'

crew add-persona growth --name Gus --consult-on launch,user-facing \
  --lens 'Who is the first person to try this, and where do they hear of it?\nWhat is the one-line reason to share it?\nHow do we measure that it worked?'
```

Use `--role pm`, `qa`, `design`, `marketing`, `user` or `architect` to add a second persona with a built-in lens. A duplicate id exits 2.

A `--name` must match `^[A-Za-z][A-Za-z0-9-]{1,23}$`, the same rule as the lead name. `crew add-component` refuses a `--dir` that does not exist. Create the folder first.

## Tests

```sh
python3 -m unittest discover -s crew-kit/tests -t crew-kit
```
