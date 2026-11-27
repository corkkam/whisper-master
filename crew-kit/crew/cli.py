"""The crew command line: every parser lives here. Each command runs in its own module."""
from __future__ import annotations

import argparse
import contextlib
import importlib
import io
import sys

from crew import __version__

# command -> (module, function). The function takes the parsed args and returns an exit code.
HANDLERS = {
    "init": ("init", "run_init"),
    "install": ("init", "run_install"),
    "add-component": ("init", "run_add_component"),
    "add-persona": ("init", "run_add_persona"),
    "doctor": ("doctor", "run_doctor"),
    "route": ("route", "run_route"),
    "run": ("runner", "run_run"),
    "loop": ("runner", "run_loop"),
    "budget": ("budget", "run_budget"),
    "statusline": ("budget", "run_statusline"),
    "status": ("control", "run_status"),
    "stop": ("control", "run_stop"),
    "resume": ("control", "run_resume"),
    "emit": ("control", "run_emit"),
    "memory": ("control", "run_memory"),
    "check-public": ("control", "run_check_public"),
    "autonomy": ("control", "run_autonomy"),
    "hook event": ("hooks", "run_hook_event"),
    "hook guard": ("guard", "run_hook_guard"),
    "hook session-start": ("hooks", "run_hook_session_start"),
}


def _pos_float(text):
    try:
        v = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError("must be a number above 0")
    if not v > 0:  # also rejects nan
        raise argparse.ArgumentTypeError("must be above 0")
    return v


def _part(text):
    try:
        v = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError("must be an integer of 1 or more")
    if v < 1:
        raise argparse.ArgumentTypeError("must be an integer of 1 or more")
    return v


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="crew", description="Crew: a per-project agent team for Claude Code.")
    p.add_argument("--version", action="version", version="crew " + __version__)
    sub = p.add_subparsers(dest="command", metavar="COMMAND")
    sub.required = True

    def cmd(name, help_):
        return sub.add_parser(name, help=help_, description=help_)

    c = cmd("init", "Set up Crew in this project.")
    c.add_argument("--lead-name", help="Name of the lead agent (required when stdin is not a TTY).")
    c.add_argument("--project-name", help="Project name (default: the folder name).")
    c.add_argument("--personas", default="pm,qa,design,marketing,user,architect",
                   help="Comma list of persona roles (default: all six).")
    c.add_argument("--no-helper", action="store_true", help="Do not add the scout helper.")
    c.add_argument("--no-agents-block", action="store_true",
                   help="Write the crew block to .crew/agents-block.pending.md only.")
    c.add_argument("--dry-run", action="store_true", help="Print the file list and write nothing.")
    c.add_argument("--force", action="store_true", help="Rewrite agent files, skills and the crew block.")

    c = cmd("install", "Copy the kit to ~/.crew/kit/<version>/ and write the shim.")
    c.add_argument("--force", action="store_true", help="Replace a copy of the same version.")

    c = cmd("add-component", "Add a component agent.")
    c.add_argument("id", metavar="ID")
    c.add_argument("--dir", required=True, help="Component folder.")
    c.add_argument("--paths", help="Comma list of path patterns (default: <dir>/).")
    c.add_argument("--name", help="Display name (default: the ID title-cased).")
    c.add_argument("--model")
    c.add_argument("--effort", choices=["low", "medium", "high", "xhigh", "max"])
    c.add_argument("--consult-on", help="Comma list of gate tags.")
    c.add_argument("--dry-run", action="store_true")

    c = cmd("add-persona", "Add a persona agent.")
    c.add_argument("id", metavar="ID")
    c.add_argument("--role", default="custom", help="A persona role or custom (default: custom).")
    c.add_argument("--name", required=True)
    c.add_argument("--consult-on", required=True, help="Comma list of gate tags.")
    c.add_argument("--lens", help="3 to 6 lines (required for custom).")
    c.add_argument("--model", default="sonnet")
    c.add_argument("--dry-run", action="store_true")

    c = cmd("doctor", "Lint the crew setup.")
    c.add_argument("--json", action="store_true")
    c.add_argument("--strict", action="store_true")
    c.add_argument("--changed", action="store_true")

    c = cmd("route", "Classify a task: assignee, advisers and gates.")
    c.add_argument("--type", required=True, help="code, qa, copy, design, research, docs or ops.")
    c.add_argument("--paths", help="Comma list of touched paths.")
    c.add_argument("--tags", help="Comma list of gate tags.")
    c.add_argument("--task", help="Task id.")
    c.add_argument("--part", type=_part, help="Part number of a split task.")
    c.add_argument("--json", action="store_true")

    c = cmd("run", "Run one task with a crew agent.")
    c.add_argument("task", metavar="TASK", nargs="?", help="Task text.")
    c.add_argument("--file", help="Read the task text from a file.")
    c.add_argument("--agent", help="Agent id (default: the lead).")
    c.add_argument("--task-id")
    c.add_argument("--approved", action="store_true")
    c.add_argument("--auto", action="store_true", help="Autonomous run.")
    c.add_argument("--max-usd", type=_pos_float, help="Lower the cap only.")
    c.add_argument("--quiet", action="store_true")
    c.add_argument("--dry-run", action="store_true")
    c.add_argument("--json", action="store_true")

    c = cmd("loop", "Run the lead in a loop (L4 and L5).")
    c.add_argument("goal", metavar="GOAL", nargs="?")
    c.add_argument("--backlog", action="store_true")
    c.add_argument("--improve", action="store_true")
    c.add_argument("--until", metavar="HH:MM")
    c.add_argument("--max-iterations", type=int, default=5)
    c.add_argument("--max-usd", type=_pos_float, help="Lower per_loop_usd only.")
    c.add_argument("--window", type=float, metavar="PCT", help="Five-hour window ceiling for this loop.")
    c.add_argument("--dry-run", action="store_true")

    c = cmd("budget", "Show spend, plan windows and STOP state.")
    c.add_argument("--json", action="store_true")
    c.add_argument("--task", help="Task id.")
    c.add_argument("--runs", type=int, help="Include the last N run rows.")
    c.add_argument("--probe", action="store_true", help="Run a tiny call to read the plan window.")

    c = cmd("status", "Show the last event of each crew agent.")
    c.add_argument("--json", action="store_true")

    c = cmd("memory", "List the files an agent loads.")
    c.add_argument("agent", metavar="AGENT")
    c.add_argument("--json", action="store_true")

    c = cmd("check-public", "Check a text file for deny words.")
    c.add_argument("--text-file", required=True)

    c = cmd("stop", "Create the STOP file.")
    c.add_argument("--global", dest="global_", action="store_true", help="Stop all projects.")
    c.add_argument("--reason", help="One word.")

    c = cmd("resume", "Delete the STOP file.")
    c.add_argument("--global", dest="global_", action="store_true")

    c = cmd("autonomy", "Set the autonomy level (a person only).")
    c.add_argument("level", metavar="LEVEL", choices=["L0", "L1", "L2", "L3", "L4", "L5"])
    c.add_argument("--days", type=int, help="Days until expiry (required for L5, at most 7).")

    c = cmd("emit", "Write one huddle event.")
    c.add_argument("event", metavar="EVENT", help="huddle.start, huddle.round or huddle.end.")
    c.add_argument("--agent", required=True)
    c.add_argument("--agents", help="Comma list of participant ids.")
    c.add_argument("--task")
    c.add_argument("--note")
    c.add_argument("--session")

    c = cmd("statusline", "Status line command: save the plan window, print a short line.")
    c.add_argument("--install", action="store_true", help="Print the settings snippet and change nothing.")

    c = cmd("hook", "Hook commands. Claude Code calls these.")
    hsub = c.add_subparsers(dest="hook_command", metavar="HOOK")
    hsub.required = True
    hsub.add_parser("event", help="Map a hook input to events.")
    hsub.add_parser("guard", help="Allow or deny a tool call.")
    hsub.add_parser("session-start", help="Session map, context and turn count.")
    return p


def _not_built(name: str) -> int:
    # A hook never prints to stderr and never blocks a session (spec 13.2, 14.3).
    if name.startswith("hook "):
        return 0
    sys.stderr.write("crew: %s is not built yet\n" % name)
    return 2


def _dispatch(args) -> int:
    name = args.command
    if name == "hook":
        name = "hook " + args.hook_command
    module, func = HANDLERS[name]
    full = "crew." + module
    try:
        mod = importlib.import_module(full)
    except ModuleNotFoundError as exc:
        # Only a missing target module means "not built yet". Any other error is a real bug.
        if exc.name != full:
            raise
        return _not_built(name)
    handler = getattr(mod, func, None)
    if handler is None:
        return _not_built(name)
    return int(handler(args) or 0)


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    if argv[:1] == ["hook"]:
        # An unknown hook command (an older kit) must not exit 2: that blocks the tool call.
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                args = build_parser().parse_args(argv)
        except SystemExit:
            return 0
        try:
            return _dispatch(args)
        except Exception:
            return 0
    return _dispatch(build_parser().parse_args(argv))
