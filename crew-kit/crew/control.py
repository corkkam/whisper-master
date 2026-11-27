"""Crew control commands: stop, resume, emit, status, memory, check-public, autonomy."""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timedelta

from crew import budget, config, events

STOP_REASONS = ("manual", "budget", "window", "stop", "level", "red-line", "protected", "doctor")


def _err(msg: str) -> None:
    sys.stderr.write(msg.rstrip("\n") + "\n")


def _project(need: bool = True):
    project = config.find_project(os.getcwd())
    if project is None and need:
        _err("crew: not inside a crew project (no .crew/crew.json above the current folder)")
    return project


def _person(cmd: str) -> bool:
    """Only a person at a terminal may run this command. The Bash tool of an agent has no TTY."""
    try:
        if sys.stdin.isatty():
            return True
    except (AttributeError, ValueError):
        pass
    _err("crew: %s needs a person at a terminal (stdin is not a TTY)" % cmd)
    return False


def _lead(project) -> str:
    cfg = config.load(project)[0] if project else {}
    return cfg.get("lead") or "lead"


# ---------------------------------------------------------------- stop and resume

def run_stop(args) -> int:
    glob = bool(getattr(args, "global_", False))
    project = _project(need=not glob)
    if project is None and not glob:
        return 8
    path = os.path.join(config.crew_home() if glob else os.path.join(project, ".crew"), "STOP")
    words = (getattr(args, "reason", None) or "").split()
    reason = words[0] if words else "manual"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("stopped %s %s\n" % (config.utc_ts(), reason))
    if project:
        config.append_ledger(project, budget.event_row("stop.on", reason if reason in STOP_REASONS else "manual"))
        events.write_event(project, "stop.on", _lead(project))
    print("crew: STOP set: %s" % path)
    return 0


def run_resume(args) -> int:
    if not _person("crew resume"):
        return 2
    glob = bool(getattr(args, "global_", False))
    project = _project(need=not glob)
    if project is None and not glob:
        return 8
    path = os.path.join(config.crew_home() if glob else os.path.join(project, ".crew"), "STOP")
    try:
        os.remove(path)
    except FileNotFoundError:
        print("crew: no STOP file at %s" % path)
        return 0
    if project:
        config.append_ledger(project, budget.event_row("stop.off", "manual"))
        events.write_event(project, "stop.off", _lead(project))
    print("crew: STOP cleared: %s" % path)
    return 0


# ---------------------------------------------------------------- emit

def run_emit(args) -> int:
    event = getattr(args, "event", None) or ""
    if event not in ("huddle.start", "huddle.round", "huddle.end"):
        _err("crew: emit takes huddle.start, huddle.round or huddle.end")
        return 2
    agent = getattr(args, "agent", None)
    if not agent:
        _err("crew: --agent is required")
        return 2
    note = getattr(args, "note", None)
    if note is not None and note not in events.NOTES:
        _err("crew: the note is not in the fixed list")
        return 2
    project = _project()
    if project is None:
        return 8
    cfg, _ = config.load(project)
    ids = {a.get("id") for a in cfg.get("agents") or []}
    group = [x for x in (getattr(args, "agents", None) or "").split(",") if x]
    for i in [agent] + group:
        if i not in ids:
            _err("crew: unknown agent: %s" % i)
            return 2
    events.write_event(project, event, agent, src="crew", session=getattr(args, "session", None), note=note,
                       agents=group)
    return 0


# ---------------------------------------------------------------- status

def _tail_events(project: str, lines: int = 2000) -> list:
    path = os.path.join(config.crew_home(), "events.jsonl")
    try:
        with open(path, "rb") as fh:
            size = os.fstat(fh.fileno()).st_size
            fh.seek(max(0, size - lines * 1100))
            data = fh.read().split(b"\n")
    except OSError:
        return []
    out, want, seen = [], os.path.realpath(project), {}
    for raw in data[-lines:]:
        try:
            e = json.loads(raw)
        except ValueError:
            continue
        p = e.get("project") if isinstance(e, dict) else None
        if isinstance(p, str):
            if p not in seen:  # CREW_PROJECT and find_project may differ by a symlink such as /tmp
                seen[p] = os.path.realpath(p) == want
            if seen[p]:
                out.append(e)
    return out


def run_status(args) -> int:
    project = _project()
    if project is None:
        return 8
    cfg, _ = config.load(project)
    last = {}
    for e in _tail_events(project):
        last[e.get("agent")] = e
    rows = []
    for a in cfg.get("agents") or []:
        e = last.get(a.get("id"))
        rows.append({"id": a.get("id"), "name": a.get("name") or a.get("id"), "role": a.get("role"),
                     "last_event": e.get("event") if e else None, "ts": e.get("ts") if e else None,
                     "note": e.get("note") if e else None})
    out = {"level": config.effective_level(cfg, config.read_ledger(project)),
           "stop": {"project": os.path.exists(os.path.join(project, ".crew", "STOP")),
                    "global": os.path.exists(os.path.join(config.crew_home(), "STOP"))},
           "agents": rows}
    if getattr(args, "json", False):
        print(json.dumps(out, indent=2))
        return 0
    print("level %s, STOP: %s" % (out["level"], "set" if any(out["stop"].values()) else "not set"))
    for r in rows:
        print("%-12s %-10s %s %s %s" % (r["id"], r["role"], r["last_event"] or "-", r["ts"] or "", r["note"] or ""))
    return 0


# ---------------------------------------------------------------- memory

def _file_info(project: str, path: str, max_lines=None):
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    lines = data.split(b"\n")
    if max_lines and len(lines) > max_lines:
        data = b"\n".join(lines[:max_lines])
        lines = lines[:max_lines]
    return {"path": os.path.relpath(path, project), "bytes": len(data), "lines": len(lines)}


def run_memory(args) -> int:
    project = _project()
    if project is None:
        return 8
    cfg, _ = config.load(project)
    agent_id = getattr(args, "agent", None)
    a = config.agent(cfg, agent_id or "")
    if a is None:
        _err("crew: unknown agent: %s" % agent_id)
        return 2
    cdir = a.get("component_dir") if a.get("role") == "component" else None
    paths = [(os.path.join(project, n), None) for n in ("AGENTS.md", "CLAUDE.md")]
    paths.append((os.path.join(project, ".claude", "agents", agent_id + ".md"), None))
    paths.append((os.path.join(project, ".claude", "agent-memory", agent_id, "MEMORY.md"), 200))
    if agent_id == cfg.get("lead"):
        paths.append((os.path.join(project, ".crew", "STATE.md"), None))
    if cdir:
        paths += [(os.path.join(project, cdir, n), None) for n in ("INTERFACE.md", "DECISIONS.md")]
        # Claude Code loads only CLAUDE.md from a subfolder, so only that file is listed.
        cur = project
        for part in [p for p in cdir.strip("/").split("/") if p and p != "."]:
            cur = os.path.join(cur, part)
            paths.append((os.path.join(cur, "CLAUDE.md"), None))
    files = [i for i in (_file_info(project, p, m) for p, m in paths) if i]
    if getattr(args, "json", False):
        print(json.dumps({"agent": agent_id, "files": files}, indent=2))
    else:
        for f in files:
            print("%-60s %6d bytes %5d lines" % (f["path"], f["bytes"], f["lines"]))
    return 0


# ---------------------------------------------------------------- check-public

def run_check_public(args) -> int:
    path = getattr(args, "text_file", None)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read().lower()
    except (OSError, TypeError) as exc:
        _err("crew: cannot read the text file: %s" % exc)
        return 2
    project = config.find_project(os.getcwd())
    cfg = config.load(project)[0] if project else {}
    words = (cfg.get("doctor") or config.DEFAULTS["doctor"]).get("deny_words")
    if words is None:
        words = config.DEFAULTS["doctor"]["deny_words"]
    hits = [w for w in words if w.lower() in text]
    for w in hits:
        print(w)
    return 7 if hits else 0


# ---------------------------------------------------------------- autonomy

def run_autonomy(args) -> int:
    """`crew autonomy L0..L5 [--days N]`. A person runs it. The guard denies it to crew agents."""
    level = getattr(args, "level", None) or ""
    days = getattr(args, "days", None)
    if not re.fullmatch(r"L[0-5]", level):
        _err("crew: the level is L0 to L5")
        return 2
    n = int(level[1])
    if n == 5 and not days:
        _err("crew: L5 needs --days (at most 7)")
        return 2
    limit = {4: 30, 5: 7}.get(n)
    if days is not None and (days < 1 or (limit and days > limit)):
        _err("crew: --days must be 1 to %s" % (limit or "any number"))
        return 2
    if n == 4 and days is None:
        days = 30
    if not _person("crew autonomy"):
        return 2
    project = _project()
    if project is None:
        return 8
    path = os.path.join(project, ".crew", "crew.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError) as exc:
        _err("crew: cannot read crew.json: %s" % exc)
        return 7
    now = datetime.now().astimezone()
    auto = raw.setdefault("autonomy", {})
    old = auto.get("level")
    auto["level"] = level
    auto["set_at"] = now.isoformat(timespec="milliseconds")
    auto["expires_at"] = (now + timedelta(days=days)).isoformat(timespec="milliseconds") if days else None
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(raw, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
    config.append_ledger(project, budget.event_row("autonomy", "manual", level_from=old, level_to=level))
    print("crew: autonomy %s -> %s%s" % (old, level, ", expires " + auto["expires_at"] if days else ""))
    return 0
