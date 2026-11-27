"""Crew config, ledger, session map and identity helpers. Standard library only."""
from __future__ import annotations

import contextlib
import copy
import fcntl
import fnmatch
import json
import os
import re
from datetime import datetime, timedelta, timezone
from typing import Mapping

# The section 4 defaults. Always deep-copy before use. A key that has no default
# (agents, lead, project.name, autonomy.set_at) is required in crew.json.
DEFAULTS: dict = {
    "version": 1,
    "project": {"public_paths": []},
    "gates": {
        "tags": ["data-format", "public-api", "privacy", "security", "user-facing",
                 "pricing", "release", "irreversible", "launch"],
        "rules": [],
    },
    "routing": [],
    "huddle": {
        "max_advisers": 3,
        "max_subjects": 3,
        "priority": ["pm", "user", "design", "marketing", "qa", "architect"],
        "max_words": 300,
        "hard_block_tags": ["privacy", "security", "irreversible", "pricing", "release"],
        "owner_tags": ["privacy", "security", "pricing", "release", "irreversible"],
    },
    "budget": {
        "per_task_usd": 3.0,
        "per_day_usd": 10.0,
        "per_loop_usd": 5.0,
        "call_reserve_usd": {"opus": 1.0, "default": 0.3},
        "cap_headroom": 1.0,
        # The plan window is the main budget (build-notes, owner decision 19:20).
        "max_five_hour_pct": 90,
        "max_seven_day_pct": 80,
        "snapshot_max_age_s": 600,
        "snapshot_max_age_auto_s": 120,
        "allow_unknown_window": False,
        "overage_guard_verified": False,
        "account": None,
    },
    # Build-notes: new crews start at L2, not L3.
    "autonomy": {"level": "L2", "expires_at": None, "set_by": "owner"},
    "guard": {"protected": [], "deny_bash": []},
    "eval": {"commands": ['"$HOME"/.crew/bin/crew doctor'], "timeout_s": 1800},
    "doctor": {
        "deny_words": ["revenue", "invoice", "pricing model", "growth strategy",
                       "go-to-market", "customer list"],
        "interface_max_age_days": 60,
    },
    "context": {"max_turns": 8},
}

BUILTIN_PROTECTED: list = [
    ".crew/crew.json",
    ".crew/ledger.jsonl",
    ".crew/ledger.lock",
    ".crew/STOP",
    ".crew/.gitignore",
    ".crew/evals/",
    ".crew/tasks/*/route.json",  # only crew route writes it: it holds the owner gate and the gate tags
    "scripts/session-context.sh",
    "**/.git/",
    "**/.mcp.json",
    "**/.claude/settings.json",
    "**/.claude/settings.local.json",
    "**/.claude/hooks/",
    "**/.claude/commands/",
    "**/crew-kit/",
    "**/eval/",
    "**/evals/",
    "**/.github/workflows/",
]

TIER_B: list = [".claude/agents/", ".claude/skills/", "AGENTS.md"]

_SESSION_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
_WORKTREE = re.compile(r"/\.claude/worktrees/[^/]+(?=/|$)")
_WORKTREE_TAIL = re.compile(r"(?:^|/)\.claude/worktrees/[^/]+(?=/|$)")


def crew_home() -> str:
    home = os.environ.get("CREW_HOME") or "~/.crew"
    path = os.path.expanduser(home)
    return path.rstrip("/") or "/"


def find_project(start: str):
    d = os.path.abspath(os.path.expanduser(start))
    home = os.path.abspath(os.path.expanduser("~"))
    while d != "/" and d != home:
        if os.path.isfile(os.path.join(d, ".crew", "crew.json")):
            return d
        d = os.path.dirname(d)
    return None


def _merge(base, user):
    out = copy.deepcopy(base)
    for key, val in user.items():
        if isinstance(out.get(key), dict) and isinstance(val, dict):
            out[key] = _merge(out[key], val)
        else:
            out[key] = copy.deepcopy(val)
    return out


def load(project: str):
    path = os.path.join(project, ".crew", "crew.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except FileNotFoundError:
        return {}, ["crew.json not found: " + path]
    except (OSError, ValueError) as exc:
        return {}, ["crew.json cannot be read: %s" % exc]
    if not isinstance(raw, dict):
        return {}, ["crew.json must hold a JSON object"]
    # The spec names (five_hour_max_pct) fill the names the code reads, unless both are set.
    b = raw.get("budget")
    if isinstance(b, dict):
        for spec_name, name in (("five_hour_max_pct", "max_five_hour_pct"),
                                ("seven_day_max_pct", "max_seven_day_pct")):
            if spec_name in b and name not in b:
                b[name] = b[spec_name]
    cfg = _merge(DEFAULTS, raw)
    errors = []
    for key, default in DEFAULTS.items():
        if isinstance(default, dict) and not isinstance(cfg.get(key), dict):
            errors.append("%s must be an object" % key)
    if raw.get("version") != 1:
        errors.append("version must be 1")
    auto = cfg.get("autonomy")
    if isinstance(auto, dict) and (not auto.get("set_at") or _parse_ts(auto["set_at"]) is None):
        errors.append("autonomy.set_at is required and must be an ISO 8601 time")
    pr = cfg.get("project")
    if not (isinstance(pr, dict) and isinstance(pr.get("name"), str) and pr["name"]):
        errors.append("project.name is required")
    agents = cfg.get("agents")
    ids = []
    if not isinstance(agents, list):
        errors.append("agents must be a list")
    else:
        for a in agents:
            if isinstance(a, dict) and isinstance(a.get("id"), str):
                ids.append(a["id"])
            else:
                errors.append("every agent needs a string id")
                break
    if not isinstance(cfg.get("lead"), str) or cfg.get("lead") not in ids:
        errors.append("lead must be the id of an agent")
    return cfg, errors


def agent(cfg: dict, agent_id: str):
    for a in cfg.get("agents") or []:
        if isinstance(a, dict) and a.get("id") == agent_id:
            return a
    return None


def _agent_ids(cfg: dict) -> set:
    return {a["id"] for a in (cfg.get("agents") or [])
            if isinstance(a, dict) and isinstance(a.get("id"), str)}


def account(cfg: dict) -> str:
    name = (cfg.get("budget") or {}).get("account")
    if name:
        return str(name)
    name = os.environ.get("CREW_ACCOUNT")
    if name:
        return name
    conf = os.environ.get("CLAUDE_CONFIG_DIR")
    if conf:
        base = os.path.basename(conf.rstrip("/"))
        if base.startswith("."):
            base = base[1:]
        if base.startswith("claude-"):
            base = base[len("claude-"):]
        if base:
            return base
    return "default"


def path_matches(rel: str, pattern: str) -> bool:
    # The owner's volume ignores case, so '.crew/CREW.json' opens '.crew/crew.json'.
    # Compare lower-case strings: a broader match is the safe side for a gate rule.
    rel = rel.lower()
    pattern = pattern.lower()
    if pattern.startswith("**/"):
        rest = pattern[3:]
        segs = rel.split("/")
        if rest.endswith("/"):
            want = rest.strip("/").split("/")
            n = len(want)
            return any(segs[i:i + n] == want for i in range(len(segs) - n + 1))
        # A file name or a glob at any depth: test every tail of the path.
        return any(fnmatch.fnmatchcase("/".join(segs[i:]), rest) for i in range(len(segs)))
    if pattern.endswith("/"):
        return (rel + "/").startswith(pattern)
    return fnmatch.fnmatchcase(rel, pattern)


def rel_path(project: str, path: str, cwd: str):
    p = os.path.expanduser(path)
    if not os.path.isabs(p):
        p = os.path.join(cwd, p)
    p = os.path.normpath(p)
    root = os.path.normpath(project)
    prefix = root.rstrip("/") + "/"
    if p == root:
        return ".", None
    if p.startswith(prefix):
        # Strip the worktree segment from the part inside the project only.
        # The root path may itself hold a worktree segment.
        tail = p[len(prefix):]
        m = _WORKTREE_TAIL.search(tail)
        if not m:
            return tail, None
        name = m.group(0).rsplit("/", 1)[1]
        tail = (tail[:m.start()] + tail[m.end():]).strip("/")
        return tail or ".", name
    worktree = None
    m = _WORKTREE.search(p)
    if m:
        worktree = m.group(0).rsplit("/", 1)[1]
        p = os.path.normpath(p[:m.start()] + p[m.end():] or "/")
        if p == root:
            return ".", worktree
        if p.startswith(prefix):
            return p[len(prefix):], worktree
    return None, worktree


def is_protected(cfg: dict, rel: str) -> bool:
    extra = (cfg.get("guard") or {}).get("protected") or []
    return any(path_matches(rel, pat) for pat in list(BUILTIN_PROTECTED) + list(extra))


def stop_set(project) -> bool:
    if project and os.path.exists(os.path.join(project, ".crew", "STOP")):
        return True
    return os.path.exists(os.path.join(crew_home(), "STOP"))


@contextlib.contextmanager
def ledger_lock(project: str):
    d = os.path.join(project, ".crew")
    os.makedirs(d, exist_ok=True)
    fd = os.open(os.path.join(d, "ledger.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def utc_ts() -> str:
    now = datetime.now(timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (now.microsecond // 1000)


def append_ledger(project: str, row: dict) -> None:
    out = {}
    if "t" in row:
        out["t"] = row["t"]
    out["v"] = 1
    out["ts"] = row.get("ts") or utc_ts()
    for key, val in row.items():
        if key not in out:
            out[key] = val
    data = (json.dumps(out, separators=(",", ":")) + "\n").encode("utf-8")
    with ledger_lock(project):
        fd = os.open(os.path.join(project, ".crew", "ledger.jsonl"),
                     os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)


def read_ledger(project: str, tail_bytes=None):
    path = os.path.join(project, ".crew", "ledger.jsonl")
    try:
        with open(path, "rb") as fh:
            size = os.fstat(fh.fileno()).st_size
            cut = bool(tail_bytes) and size > tail_bytes
            if cut:
                # Start one byte early, so a cut on a line boundary keeps the whole line.
                fh.seek(size - tail_bytes - 1)
            data = fh.read()
    except OSError:
        return []
    lines = data.split(b"\n")
    if cut:
        lines = lines[1:]  # the first piece is partial, or empty after the extra byte
    rows = []
    for line in lines:
        if not line.strip():
            continue
        try:
            row = json.loads(line.decode("utf-8"))
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def _parse_ts(value):
    try:
        s = str(value).strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        d = datetime.fromisoformat(s)
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def spent(rows, *, day=None, task_id=None, loop_id=None) -> float:
    closed = {r.get("run_id") for r in rows if r.get("t") == "run"}
    total = 0.0
    for r in rows:
        kind = r.get("t")
        if kind == "run":
            amount = r.get("cost_usd")
        elif kind == "reserve" and r.get("run_id") not in closed:
            amount = r.get("cap_usd")
        else:
            continue
        if task_id is not None and r.get("task_id") != task_id:
            continue
        if loop_id is not None and r.get("loop_id") != loop_id:
            continue
        if day is not None:
            d = _parse_ts(r.get("ts"))
            if d is None or d.astimezone().date().isoformat() != day:
                continue
        try:
            total += float(amount or 0)
        except (TypeError, ValueError):
            continue
    return total


def effective_level(cfg: dict, rows, now=None) -> str:
    auto = cfg.get("autonomy") or {}
    m = re.fullmatch(r"L([0-5])", str(auto.get("level")))
    if not m:
        return "L0"  # an invalid level fails safe
    level = int(m.group(1))
    now = now or datetime.now(timezone.utc)
    set_at = _parse_ts(auto.get("set_at")) if auto.get("set_at") else None
    if level >= 4:
        expires = _parse_ts(auto.get("expires_at")) if auto.get("expires_at") else None
        limit = None
        if set_at is not None:
            limit = set_at + timedelta(days=30 if level == 4 else 7)
        if expires is None or limit is None or expires <= now or expires > limit:
            level = 3
    for r in rows:
        if r.get("t") == "event" and r.get("kind") == "demote":
            ts = _parse_ts(r.get("ts"))
            # An unreadable ts counts: that is the safe side.
            if set_at is None or ts is None or ts > set_at:
                level -= 1
    return "L%d" % max(0, level)


def session_file(session_id: str) -> str:
    if not _SESSION_ID.match(str(session_id)):
        raise ValueError("bad session id")
    return os.path.join(crew_home(), "sessions", str(session_id) + ".json")


def read_session(session_id):
    if not session_id:
        return None
    try:
        with open(session_file(session_id), "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def write_session(session_id: str, data: dict) -> None:
    path = session_file(session_id)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, path)


def resolve_project(hook: dict, env: Mapping[str, str]):
    p = env.get("CREW_PROJECT")
    if p and os.path.isfile(os.path.join(p, ".crew", "crew.json")):
        return p
    sess = read_session(hook.get("session_id"))
    if sess and isinstance(sess.get("project"), str) and sess["project"]:
        return sess["project"]
    cwd = hook.get("cwd")
    return find_project(cwd) if cwd else None


def resolve_agent(hook: dict, cfg: dict, env: Mapping[str, str]):
    ids = _agent_ids(cfg)
    atype = hook.get("agent_type")
    if atype in ids:
        return atype, False
    sess = read_session(hook.get("session_id"))
    if sess and isinstance(sess.get("agent"), str) and sess["agent"]:
        return sess["agent"], bool(hook.get("agent_id") or atype)
    name = env.get("CREW_AGENT")
    if name in ids:
        return name, False
    return None, False
