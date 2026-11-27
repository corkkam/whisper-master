"""crew hook guard: the PreToolUse guard (spec section 14.3, steps 0 to 11).

decide() returns a deny note or None. run_hook_guard() prints the deny JSON and always exits 0.
A session that is not a crew session is always allowed, as the first check (build-notes WP2).
"""
from __future__ import annotations

import json
import os
import re
import sys
import time  # local date for the day cap only

from crew import config, events, redlines

READ_ONLY = frozenset(["Read", "Grep", "Glob", "LS", "NotebookRead"])
EDIT_TOOLS = frozenset(["Edit", "Write", "MultiEdit", "NotebookEdit"])
PERSONA_ROLES = frozenset(["pm", "qa", "design", "marketing", "user", "architect", "custom"])

_RO_GIT = re.compile(r"^\s*git(\s+-C\s+\S+)?\s+(status|log|diff|show|rev-parse|branch\s+--show-current)\b")
_SAFE_CREW = re.compile(
    r'^\s*(?:crew|"\$HOME"/\.crew/bin/crew|\$HOME/\.crew/bin/crew|~/\.crew/bin/crew)\s+'
    r"(route|emit|budget(?![^;&|\n]*--probe)|status|doctor|memory|check-public)\b")
# Global options may come before the subcommand ("git -C . commit"). Case is ignored, as in redlines.
_OWNER_BASH = re.compile(redlines.GIT + r"(commit|push|merge|rebase)\b|" + redlines.GH + r"pr\s+create\b",
                         re.IGNORECASE)
_PUBLIC_BASH = re.compile(redlines.GIT + r"(commit|tag|checkout\s+-b|switch\s+-c|branch)\b|" + redlines.GH
                          + r"pr\s+(create|edit)\b", re.IGNORECASE)
_HOSTS = re.compile("|".join(redlines.HOSTS), re.IGNORECASE)
_TASK_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_WRITE_OPS = (">", "rm ", "mv ", "cp ", "tee ", "sed -i", "perl ", "python", "chmod ", "ln ",
              "truncate", "dd ", "install ", "git checkout", "git restore", "git apply", "patch ")
_AUDIO = re.compile(r"\.(?:wav|m4a|caf|aiff|flac|mp3)(?![\w-])", re.IGNORECASE)
_FIXTURES = re.compile(r"Fixtures/audio(?![\w.-])")
# Library/<any one folder>/<...>WhisperMaster: Application Support, Containers, and globs such as Application*.
_LIBRARY = re.compile(r"/Library/[^/\n]*/[^/\n]*WhisperMaster")
# a chain, a redirect or a subshell: the command is more than one plain command.
_CHAIN = re.compile(r"[;&|\n`<>]|\$\(")
# the documented shim path at command position; its ".crew" text is not a write target.
_SHIM = re.compile(r'(^|[;&|(\n])\s*(?:"\$HOME"|\$HOME|\$\{HOME\}|~)/\.crew/bin/crew\s')
_DEMOTE = {"denied: protected path": "protected", "denied: red line": "red-line",
           "denied: tool": "tool", "denied: private data": "private-data"}


class _Ctx(object):
    """What run_hook_guard needs to write the deny event and the demote row."""

    def __init__(self):
        self.project = None
        self.agent = None
        self.smap = None
        self.autonomous = False
        self.level = None
        self.cfg = None


def decide(hook: dict, env) -> str | None:
    return _decide(hook, env, _Ctx())


def _decide(hook, env, ctx):
    known = False
    try:
        # 1. Only PreToolUse is guarded.
        if not isinstance(hook, dict) or hook.get("hook_event_name") != "PreToolUse":
            return None
        # 2. Project and agent. A session that is not a crew session is allowed.
        sid = hook.get("session_id")
        smap = config.read_session(sid) if isinstance(sid, str) and sid else None
        ctx.smap = smap
        if not smap and not env.get("CREW_AGENT") and not hook.get("agent_type"):
            return None  # owner session: no crew identity is possible (build-notes WP2, checked first)
        project = config.resolve_project(hook, env)
        ctx.project = project
        cfg, errors = config.load(project) if project else ({}, ["no project"])
        if errors:
            if not _crew_without_config(hook, env, smap, project):
                return None
            known = True
            ctx.agent = _fallback_agent(hook, env, smap)
            # 3. Fail closed for a crew agent.
            return "denied: config"
        agent_id, _builtin = config.resolve_agent(hook, cfg, env)
        if agent_id is None:
            return "denied: config" if smap else None
        known = True
        ctx.agent, ctx.cfg = agent_id, cfg
        ctx.autonomous = bool(smap.get("autonomous")) if smap else env.get("CREW_AUTONOMOUS") == "1"
        me = config.agent(cfg, agent_id)
        if me is None:
            return "denied: config"
        role = me.get("role")

        # 4. STOP blocks crew sessions only.
        if config.stop_set(project):
            return "denied: stop"

        # 5. Tool allowlist.
        tool = hook.get("tool_name")
        if tool not in redlines.ALLOWED_TOOLS:
            return "denied: tool"
        tin = hook.get("tool_input")
        if not isinstance(tin, dict):
            tin = {}

        # 6. Delegation: only the lead, and only to a crew agent of this project.
        if tool in ("Agent", "Task"):
            sub = tin.get("subagent_type")
            if role != "lead" or not isinstance(sub, str) or config.agent(cfg, sub) is None:
                return "denied: tool"

        cwd = hook.get("cwd") if isinstance(hook.get("cwd"), str) and hook.get("cwd") else project
        command = tin.get("command") if tool == "Bash" else None
        if tool == "Bash" and not isinstance(command, str):
            command = ""
        path = real = None
        rel = rel_real = wt = None
        scratch = False
        if tool in EDIT_TOOLS:
            path = tin.get("file_path") or tin.get("notebook_path")
            if isinstance(path, str) and path:
                rel, wt = config.rel_path(project, path, cwd)
                # A symlink made with Bash must not lead a write into a protected file: check the real path too.
                real = os.path.realpath(os.path.join(cwd, os.path.expanduser(path)))
                rel_real = config.rel_path(os.path.realpath(project), real, cwd)[0]
            else:
                path = None
            scratch = all(r is not None and (r.startswith(".crew/tasks/") or
                                             r.startswith(".claude/agent-memory/%s/" % agent_id))
                          for r in (rel, rel_real))

        # 7. Level, approval and budget.
        rows = config.read_ledger(project, tail_bytes=262144)
        level = config.effective_level(cfg, rows)
        ctx.level = level
        if level == "L0" and tool not in READ_ONLY:
            return "denied: level"
        if level == "L1":
            if tool in EDIT_TOOLS and not scratch:
                return "denied: level"
            if tool == "Bash" and not _l1_bash_ok(command):
                return "denied: level"
        task_id = env.get("CREW_TASK_ID") or (smap.get("task_id") if smap else None)
        route = _read_route(project, task_id)
        approved = bool(smap.get("approved")) if smap else False
        if not approved and (level == "L2" or (isinstance(route, dict) and route.get("owner_gate") is True)):
            if tool in EDIT_TOOLS and not scratch:
                return "denied: needs owner"
            if tool == "Bash" and _OWNER_BASH.search(command):
                return "denied: needs owner"
        if tool not in READ_ONLY:
            per_day = (cfg.get("budget") or {}).get("per_day_usd", 10.0)
            if per_day is not None and config.spent(rows, day=time.strftime("%Y-%m-%d")) >= float(per_day):
                return "denied: budget"

        # 8. Private data.
        if tool in READ_ONLY:
            names = [tin.get(k) for k in ("file_path", "path", "notebook_path")]
            if tool == "Glob":
                names.append(tin.get("pattern"))
            if any(isinstance(n, str) and (_private(n) or _secret(n)) for n in names):
                return "denied: private data"
        if tool == "Bash" and (_private(command) or _secret(command)):
            return "denied: private data"
        if tool == "WebFetch" and _HOSTS.search(str(tin.get("url") or "")):
            return "denied: red line"

        # 9. Writes.
        if tool in EDIT_TOOLS:
            if path is None:
                return "denied: outside paths"
            absolute = os.path.normpath(os.path.join(cwd, os.path.expanduser(path)))
            if _under_home_guarded(absolute) or _under_home_guarded(real):
                return "denied: protected path"
            if rel is None or rel_real is None:
                return "denied: outside paths"
            for r in (rel, rel_real):
                if config.is_protected(cfg, r):
                    return "denied: protected path"
                if any(config.path_matches(r, p) for p in config.TIER_B) and not (wt or "").startswith("crew-improve-"):
                    return "denied: protected path"
            if task_id:
                if route is None and not scratch:
                    return "denied: ungated"
                if isinstance(route, dict):
                    have = set(route.get("gate_tags") or [])
                    for rule in (cfg.get("gates") or {}).get("rules") or []:
                        if rule.get("tag") not in have and any(
                                config.path_matches(rel, p) for p in rule.get("paths") or []):
                            return "denied: ungated"
            if role != "lead" and not scratch:
                for r in (rel, rel_real):
                    if not any(config.path_matches(r, p) for p in me.get("paths") or []):
                        return "denied: outside paths"
            return None

        # 10. Bash.
        if tool == "Bash":
            if redlines.check(command, list((cfg.get("guard") or {}).get("deny_bash") or [])):
                return "denied: red line"
            if tin.get("run_in_background") is True:
                return "denied: red line"  # the tool's own background mode is the "&" red line
            if not (_single(command) and events.kind_for("Bash", command) in ("test", "build")):
                # Remove quotes and backslashes: "led''ger.jsonl" names the ledger to the shell.
                text = re.sub(r"[\"'\\]", "", _SHIM.sub(r"\1 ", command))
                if any(op in text for op in _WRITE_OPS) and any(
                        s in text for s in _protected_strings(cfg, project)):
                    return "denied: protected path"
            if (cfg.get("project") or {}).get("public_paths") and _PUBLIC_BASH.search(command):
                low = command.lower()
                if any(w and w.lower() in low for w in (cfg.get("doctor") or {}).get("deny_words") or []):
                    return "denied: public text"

        # 11. Allow.
        return None
    except Exception:
        # 0. Before the agent is known: allow. After: fail closed.
        return "denied: config" if known else None


def _crew_without_config(hook, env, smap, project):
    """Is this a crew session when crew.json is missing or broken? (build-notes WP2)."""
    if smap or env.get("CREW_AGENT"):
        return True
    at = hook.get("agent_type")
    if not (isinstance(at, str) and at and project):
        return False
    try:
        with open(os.path.join(project, ".crew", "crew.json"), "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read(65536)
    except OSError:
        return False
    # shortcut: a text search for the id in broken JSON. It may miss an id written in an odd form.
    return re.search(r'"id"\s*:\s*"%s"' % re.escape(at), raw) is not None


def _fallback_agent(hook, env, smap):
    if smap and isinstance(smap.get("agent"), str):
        return smap["agent"]
    return env.get("CREW_AGENT") or hook.get("agent_type") or None


def _single(command):
    """One plain command: no chain, pipe, redirect or subshell. "2>&1" is allowed."""
    return not _CHAIN.search(re.sub(r"\s\d*>&\d+", " ", command or ""))


def _l1_bash_ok(command):
    if not _single(command):
        return False
    return (events.kind_for("Bash", command) in ("search", "test")
            or bool(_RO_GIT.search(command)) or bool(_SAFE_CREW.search(command)))


def _read_route(project, task_id):
    """The route.json dict, or None when there is no task or no file. Bad JSON raises."""
    if not task_id or not _TASK_ID.match(str(task_id)):
        return None
    path = os.path.join(project, ".crew", "tasks", str(task_id), "route.json")
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    return data if isinstance(data, dict) else {}


def _home():
    return os.path.normpath(os.path.expanduser("~"))


def _expand(text):
    home = _home()
    text = text.replace("\\ ", " ")
    text = re.sub(r"(?<![\w/])~(?=/|$|[\s'\"])", home, text)
    return text.replace("${HOME}", home).replace("$HOME", home)


def _private(text):
    if not text:
        return False
    t = _expand(text).replace('"', "").replace("'", "")
    return (bool(_LIBRARY.search(t))
            or bool(_FIXTURES.search(t))
            or bool(_AUDIO.search(t)))


def _under_home_guarded(absolute):
    if not absolute:
        return False
    for ch in {os.path.normpath(config.crew_home()), os.path.realpath(config.crew_home())}:
        if absolute == ch or absolute.startswith(ch.rstrip("/") + "/"):
            return True
    for h in {_home(), os.path.realpath(_home())}:
        home = h.rstrip("/") + "/"
        if absolute.startswith(home) and absolute[len(home):].split("/", 1)[0].lower().startswith(".claude"):
            return True
    return False


def _secret(text):
    """Key, token and credential files: ~/.ssh, ~/.aws, ~/.gnupg, ~/.config/gh, keychains, ~/.claude*/.credentials*, .env."""
    if not text:
        return False
    t = _expand(text).replace('"', "").replace("'", "")
    homes = "|".join(re.escape(h) for h in {_home(), os.path.realpath(_home())})
    return re.search(
        r"(?:%s)/(?:\.ssh|\.aws|\.gnupg|\.config/gh|\.netrc|\.docker/config\.json)(?![\w.-])"
        r"|(?:%s)/\.claude[^/\s]*/\.credentials"
        r"|/Library/Keychains(?![\w.-])|\.keychain(?:-db)?(?![\w.-])"
        r"|(?:^|[\s/=])\.env(?!\.(?:example|sample|template)\b)(?:\.[\w.-]+)?(?![\w.-])" % (homes, homes), t, re.IGNORECASE) is not None


def _protected_strings(cfg, project):
    entries = list(config.BUILTIN_PROTECTED) + list((cfg.get("guard") or {}).get("protected") or [])
    out = []
    root = project.rstrip("/")
    for e in entries:
        e = e[3:] if e.startswith("**/") else e
        if e:
            out.extend([e, root + "/" + e])
    # shortcut: bare names catch "cd .crew && echo x > crew.json"; other cd forms stay best effort (section 10.2).
    out.extend(["crew.json", "ledger.jsonl", "route.json", "settings.json", "settings.local.json", ".crew/", "~/.crew", "$HOME/.crew", config.crew_home(), "~/.claude", "$HOME/.claude",
                root + "/.claude/agents"])
    return out


def _deny_json(note):
    return json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                              "permissionDecisionReason": "crew: " + note}})


def _lower(level):
    m = re.match(r"^L([0-5])$", str(level or ""))
    return "L%d" % max(0, int(m.group(1)) - 1) if m else None


def run_hook_guard(args) -> int:
    try:
        hook = json.loads(sys.stdin.read() or "null")
    except Exception:
        return 0
    ctx = _Ctx()
    note = _decide(hook, os.environ, ctx)
    if not note:
        return 0
    try:
        sys.stdout.write(_deny_json(note) + "\n")
        sys.stdout.flush()
    except Exception:
        pass
    try:
        if ctx.project and ctx.agent:
            events.write_event(ctx.project, "guard.deny", ctx.agent, src="crew",
                               session=hook.get("session_id"), note=note)
            if ctx.autonomous and note in _DEMOTE and ctx.cfg is not None:
                level = ctx.level or config.effective_level(ctx.cfg, config.read_ledger(ctx.project, tail_bytes=262144))
                config.append_ledger(ctx.project, {
                    "t": "event", "kind": "demote", "detail": _DEMOTE[note],
                    "run_id": (ctx.smap or {}).get("run_id") or os.environ.get("CREW_RUN_ID"),
                    "loop_id": (ctx.smap or {}).get("loop_id") or os.environ.get("CREW_LOOP_ID"), "level_from": level, "level_to": _lower(level)})
    except Exception:
        pass
    return 0
