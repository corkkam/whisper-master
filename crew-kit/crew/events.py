"""Crew events: the shared event log that the app reads. Standard library only."""
from __future__ import annotations

import json
import os
import re
from typing import Sequence

from crew import config

EVENTS = frozenset([
    "session.start", "context.clear", "prompt", "tool.start", "tool.end", "tool.fail",
    "needs.input", "agent.start", "agent.stop", "turn.end", "turn.fail", "session.end",
    "run.start", "run.end", "huddle.start", "huddle.round", "huddle.end", "budget.over",
    "stop.on", "stop.off", "guard.deny", "loop.start", "loop.end",
])

NOTES = frozenset([
    "ok", "error", "budget", "window", "stopped", "crash", "needs approval", "blocked",
    "changed", "no change", "permission", "waiting", "clear", "compact", "round 2",
    "consult capped", "denied: stop", "denied: protected path", "denied: red line",
    "denied: outside paths", "denied: config", "denied: tool", "denied: level",
    "denied: budget", "denied: private data", "denied: ungated", "denied: needs owner",
    "denied: public text", "deadline", "iterations", "plateau", "backlog empty", "probe",
])

KINDS = frozenset(["test", "build", "git", "search", "edit", "read", "web", "agent", "other"])

ROTATE_BYTES = 8 * 1024 * 1024  # tests lower this
MAX_LINE = 1024

_SRCS = frozenset(["claude", "codex", "crew"])

_TOOL_KIND = {
    "Read": "read", "NotebookRead": "read",
    "Edit": "edit", "Write": "edit", "MultiEdit": "edit", "NotebookEdit": "edit",
    "Grep": "search", "Glob": "search", "LS": "search",
    "WebFetch": "web", "WebSearch": "web",
    "Agent": "agent", "Task": "agent",
}

# A command word: line start, after a separator or subshell opener, after VAR=value words.
# shortcut: no "time", "sudo" or "env" prefix handling, add when a real command is missed.
_CMD = (r"(?:^|[;&|(\n]|\$\(|`)\s*"
        r"(?:[A-Za-z_][A-Za-z0-9_]*=(?:\$\([^)]*\)|\S*)\s+)*(?:\S*/)?")
_TEST = re.compile(_CMD + r"(?:swift\s+test|xcodebuild\s+test|pytest|python3?\s+-m\s+(?:unittest|pytest)"
                   r"|(?:npm|pnpm|yarn)\s+(?:run\s+)?test|go\s+test|cargo\s+test)\b")
_BUILD = re.compile(_CMD + r"(?:swift\s+build|xcodebuild|(?:npm|pnpm|yarn)\s+(?:run\s+)?build"
                    r"|make|cargo\s+build|go\s+build)\b")
_GIT = re.compile(r"^\s*(?:git|gh)\s|^\s*GH_TOKEN=(?:\$\([^)]*\)|\S+)\s+gh\s")
_SEARCH = re.compile(r"^\s*(?:grep|rg|ugrep|find|ls|fd)\b")


def kind_for(tool_name: str, command=None) -> str:
    if tool_name in _TOOL_KIND:
        return _TOOL_KIND[tool_name]
    if tool_name != "Bash" or not command:
        return "other"
    for kind, rx in (("test", _TEST), ("build", _BUILD), ("git", _GIT), ("search", _SEARCH)):
        if rx.search(command):
            return kind
    return "other"


def _line(obj: dict) -> bytes:
    data = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    while len(data) + 1 > MAX_LINE and obj["agents"]:
        obj["agents"] = obj["agents"][:-1]
        data = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    if len(data) + 1 > MAX_LINE:
        return b""  # still too long with no agents (a very long path): write nothing
    return data + b"\n"


def write_event(project: str, event: str, agent: str, *, src: str = "crew", session=None,
                tool=None, kind=None, note=None, agents: Sequence[str] = ()) -> None:
    try:
        if event not in EVENTS:
            return
        obj = {
            "v": 1,
            "ts": config.utc_ts(),
            "src": src if src in _SRCS else "crew",
            "event": event,
            "session": session if isinstance(session, str) else None,
            "agent": str(agent),
            "project": str(project),
            "tool": str(tool)[:64] if tool else None,
            "kind": kind if kind in KINDS else None,
            "note": note if note in NOTES else None,
            "agents": [str(a) for a in agents],
        }
        data = _line(obj)
        if not data:
            return
        home = config.crew_home()
        os.makedirs(home, exist_ok=True)
        path = os.path.join(home, "events.jsonl")
        try:
            if os.path.getsize(path) >= ROTATE_BYTES:
                # shortcut: two writers can both rotate, which may drop a few lines. Accept it.
                os.replace(path, path + ".1")
        except OSError:
            pass
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
    except Exception:
        return
