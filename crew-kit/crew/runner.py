"""Crew runner: `crew run` and `crew loop`. Spec sections 9.3, 11.1, 13.5 and 13.6."""
from __future__ import annotations

import contextlib
import hashlib
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta
from typing import Mapping, Optional

from crew import budget, config, events

STOP_POLL_S = 2.0      # tests lower these two through the module attributes
STOP_GRACE_S = 10.0
DISALLOWED = "CronCreate CronDelete RemoteTrigger SendMessage SendUserFile Monitor"
MAX_HASH_BYTES = 5 * 1024 * 1024
SKIP_DIRS = {".build", "node_modules"}
RESULT_WORDS = ("changed", "no_change", "blocked", "needs_approval")
# The run row exit_code is the exit code of crew itself, not the return code of the child.
OUTCOME_EXIT = {"ok": 0, "error": 1, "crash": 1, "budget": 9, "stopped": 130, "window": 6}
LOOP_NOTE = {"day-cap": "budget", "loop-cap": "budget", "task-cap": "budget", "window": "window",
             "overage": "window", "unknown-window": "window", "unverified": "window", "stop": "stopped",
             "deadline": "deadline", "iterations": "iterations", "plateau": "plateau",
             "backlog-empty": "backlog empty", "level": "denied: level"}


def _err(msg: str) -> None:
    sys.stderr.write(msg.rstrip("\n") + "\n")


# ---------------------------------------------------------------- argv and environment (13.5)

def build_argv(cfg: dict, agent: dict, cap: float, level: str, autonomous: bool, session_id: str,
               task_id: str) -> list:
    argv = [
        budget.claude_bin(), "-p", "--agent", agent["id"],
        "--session-id", session_id,
        "--name", "crew:%s:%s" % (agent["id"], task_id),
        "--output-format", "stream-json", "--verbose",
        "--max-budget-usd", "%.2f" % cap,
        "--max-turns", "100",
        "--model", budget.agent_model(agent), "--effort", agent.get("effort") or _default_effort(agent),
        "--settings", '{"autoContinueAtUsageLimit":false}',
        "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
        "--disallowedTools", DISALLOWED,
        "--permission-mode", "plan" if level == "L1" else "auto",
    ]
    if autonomous:
        argv += ["--permission-prompts", "none"]
    return argv


def _default_effort(agent: dict) -> str:
    return {"lead": "high", "component": "high", "helper": "low"}.get(agent.get("role"), "medium")


def child_env(environ: Mapping[str, str], extra: dict) -> dict:
    env = {}
    for k, v in environ.items():
        if k in ("CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT"):
            continue
        if k.startswith("CLAUDE_CODE_") and k != "CLAUDE_CODE_OAUTH_TOKEN":
            continue
        env[k] = v
    env.update(extra)
    return env


def _header(task_id, run_id, level, cap, approved, purpose) -> str:
    return ("[crew] task_id=%s run_id=%s level=%s cap_usd=%.2f approved=%s purpose=%s\n"
            "[crew] Follow the lead protocol. End with the crew_result line.\n\n"
            % (task_id, run_id, level, cap, "true" if approved else "false", purpose))


# ---------------------------------------------------------------- watched files (9.3 after a run, step 2)

def _kit_dir() -> str:
    """The folder of the running kit (crew-kit/ or ~/.crew/kit/<version>/). Tests patch this."""
    return os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def _hook_files(project: str, settings_path: str) -> list:
    try:
        with open(settings_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    cmds = []

    def walk(o):
        if isinstance(o, dict):
            if isinstance(o.get("command"), str):
                cmds.append(o["command"])
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(data.get("hooks") if isinstance(data, dict) else None)
    found = []
    for cmd in cmds:
        try:
            tokens = shlex.split(cmd)
        except ValueError:
            tokens = cmd.split()
        for t in tokens:
            t = os.path.expanduser(t.replace("${HOME}", "~").replace("$HOME", "~"))
            t = os.path.expanduser(t)
            path = t if os.path.isabs(t) else os.path.join(project, t)
            if os.path.isfile(path):
                found.append(path)
    return found


def _walk_files(root: str, skip_pycache: bool = False):
    """Walk a folder. Only the kit folder skips __pycache__: running crew writes .pyc files there."""
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS and not (skip_pycache and x == "__pycache__")
                   and not (x == "objects" and os.path.basename(d) == ".git")]
        for f in files:
            yield os.path.join(d, f)


def watched_hashes(project: str, cfg: dict) -> dict:
    """SHA-256 of every watched file. Keys are paths relative to the project, or absolute outside it."""
    paths = set()

    def add_file(p):
        if os.path.isfile(p):
            paths.add(p)

    def add_dir(p, skip_pycache=False):
        if os.path.isdir(p):
            paths.update(_walk_files(p, skip_pycache))

    def add_glob_dir(p, suffix=None):
        if os.path.isdir(p):
            for f in sorted(os.listdir(p)):
                if suffix is None or f.endswith(suffix):
                    add_file(os.path.join(p, f))

    for rel in (".crew/crew.json", ".crew/.gitignore", ".claude/settings.json", ".claude/settings.local.json",
                ".mcp.json", ".git/config"):
        add_file(os.path.join(project, rel))
    for rel in (".claude/settings.json", ".claude/settings.local.json"):
        paths.update(_hook_files(project, os.path.join(project, rel)))
    add_glob_dir(os.path.join(project, ".claude", "agents"), ".md")
    for rel in (".claude/skills", ".claude/commands", ".claude/hooks"):
        add_dir(os.path.join(project, rel))
    add_glob_dir(os.path.join(project, ".git", "hooks"))
    # shortcut: only plain folder prefixes under public_paths and guard.protected are walked.
    # A "**/" pattern is not expanded. Upgrade when a project needs it.
    for pat in (cfg.get("project") or {}).get("public_paths") or []:
        if pat.endswith("/") and not pat.startswith("**/"):
            repo = os.path.join(project, pat)
            add_file(os.path.join(repo, ".git", "config"))
            add_glob_dir(os.path.join(repo, ".git", "hooks"))
    for pat in list(config.BUILTIN_PROTECTED) + list((cfg.get("guard") or {}).get("protected") or []):
        if pat.endswith("/") and not pat.startswith("**/"):
            add_dir(os.path.join(project, pat))
    add_dir(_kit_dir(), skip_pycache=True)
    out = {}
    root = os.path.normpath(project) + "/"
    for p in sorted(paths):
        try:
            if os.path.getsize(p) > MAX_HASH_BYTES:
                continue
            with open(p, "rb") as fh:
                digest = hashlib.sha256(fh.read()).hexdigest()
        except OSError:
            continue
        n = os.path.normpath(p)
        out[n[len(root):] if n.startswith(root) else n] = digest
    return out


LEDGER = ".crew/ledger.jsonl"


def _ledger_mark(project: str):
    """The ledger size and the SHA-256 of its bytes. The ledger is append only."""
    try:
        with open(os.path.join(project, LEDGER), "rb") as fh:
            data = fh.read()
    except OSError:
        data = b""
    return len(data), hashlib.sha256(data).hexdigest()


def _ledger_changed(project: str, mark) -> bool:
    """True when the ledger is shorter than at the mark, or its first bytes changed."""
    size, digest = mark
    try:
        with open(os.path.join(project, LEDGER), "rb") as fh:
            data = fh.read(size + 1)
    except OSError:
        data = b""
    return len(data) < size or hashlib.sha256(data[:size]).hexdigest() != digest


def _diff_hashes(before: dict, after: dict) -> list:
    return sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))


# ---------------------------------------------------------------- one child run

class _Child:
    """The child process, its stream state and the interrupt logic."""

    def __init__(self, proc):
        self.proc = proc
        self.reason: Optional[str] = None      # "stop", "window" or "internal", set once by crew
        self.reason_detail = ""
        self.timer: Optional[threading.Timer] = None
        self.cancelled = False
        self.lock = threading.Lock()
        self.result: Optional[dict] = None
        self.last_text = ""
        self.subagents_seen = []

    def interrupt(self, reason: str, detail: str = "") -> None:
        with self.lock:
            if self.reason is not None:
                return
            self.reason, self.reason_detail = reason, detail
            try:
                os.kill(self.proc.pid, signal.SIGINT)
            except OSError:
                return
            self._arm(self._term_group)

    def _arm(self, fn) -> None:
        self.timer = threading.Timer(STOP_GRACE_S, fn)
        self.timer.daemon = True
        self.timer.start()

    def _signal_group(self, sig) -> None:
        try:
            os.killpg(self.proc.pid, sig)
        except OSError:
            pass

    def _term_group(self) -> None:
        """First grace period over: SIGTERM to the group, then SIGKILL after a second grace period."""
        with self.lock:
            if self.cancelled:
                return
            self._signal_group(signal.SIGTERM)
            self._arm(lambda: self._signal_group(signal.SIGKILL))

    def cancel(self) -> None:
        with self.lock:
            self.cancelled = True
            if self.timer:
                self.timer.cancel()


def _names(cfg: dict, ids) -> str:
    out = []
    for i in ids:
        a = config.agent(cfg, i)
        out.append((a or {}).get("name") or i)
    return ", ".join(out)


_EMIT = re.compile(r'^\s*(?:"\$HOME"/\.crew/bin/|\$HOME/\.crew/bin/|~/\.crew/bin/)?crew\s+emit\s+huddle\.(start|round|end)\b')


def _progress(obj: dict, cfg: dict, quiet: bool) -> None:
    if quiet:
        return
    if obj.get("type") == "system" and obj.get("subtype") == "task_started":
        a = config.agent(cfg, obj.get("subagent_type") or "")
        if a:
            _err("crew: %s (%s) started" % (a.get("name") or a["id"], a.get("role")))
    elif obj.get("type") == "assistant":
        content = (obj.get("message") or {}).get("content")
        for blk in content if isinstance(content, list) else []:
            if not isinstance(blk, dict) or blk.get("type") != "tool_use" or blk.get("name") != "Bash":
                continue
            cmd = (blk.get("input") or {}).get("command") or ""
            m = _EMIT.match(cmd)
            if not m:
                continue
            try:
                toks = shlex.split(cmd)
            except ValueError:
                toks = cmd.split()
            ids = []
            for i, t in enumerate(toks):
                if t == "--agents" and i + 1 < len(toks):
                    ids = [x for x in toks[i + 1].split(",") if x]
                elif t.startswith("--agents="):
                    ids = [x for x in t[9:].split(",") if x]
            _err("crew: huddle %s (%s)" % (m.group(1), _names(cfg, ids)))


def _handle_line(child: _Child, line: str, *, cfg, account, auto, window_pct, quiet) -> None:
    try:
        obj = json.loads(line)
    except ValueError:
        return
    if not isinstance(obj, dict):
        return
    kind = obj.get("type")
    if kind == "rate_limit_event":
        budget.write_snapshot(account, obj.get("rate_limit_info") or {}, "stream")
        snap = budget.read_snapshot(account)
        if budget.on_overage(snap):
            child.interrupt("window", "overage")
        elif auto and budget.at_limit(snap, cfg, window_pct):
            child.interrupt("window", "window")
    elif kind == "result":
        child.result = obj
    elif kind == "assistant" and not obj.get("parent_tool_use_id"):
        content = (obj.get("message") or {}).get("content")
        for blk in content if isinstance(content, list) else []:
            if isinstance(blk, dict) and blk.get("type") == "text" and blk.get("text"):
                child.last_text = blk["text"]
    _progress(obj, cfg, quiet)


def parse_crew_result(text: str) -> str:
    """The word of the last line that starts with {"crew_result". Missing means no_change."""
    word = "no_change"
    for line in (text or "").splitlines():
        line = line.strip()
        if line.startswith('{"crew_result"'):
            try:
                w = json.loads(line).get("crew_result")
            except ValueError:
                continue
            if w in RESULT_WORDS:
                word = w
    return word


class Result:
    """What one `crew run` produced. `row` is None when the run was refused or was a dry run."""

    def __init__(self, exit_code, refused=False, detail="", row=None, text="", crew_result=None):
        self.exit_code, self.refused, self.detail = exit_code, refused, detail
        self.row, self.text, self.crew_result = row, text, crew_result


def _reduce_usage(mu) -> dict:
    out = {}
    for model, d in (mu or {}).items():
        if isinstance(d, dict):
            out[model] = {"costUSD": d.get("costUSD"), "inputTokens": d.get("inputTokens"),
                          "outputTokens": d.get("outputTokens")}
    return out


def execute(project: str, cfg: dict, *, task: str, agent_id: str, task_id: str, approved=False, auto=False,
            max_usd=None, quiet=False, dry_run=False, purpose="task", loop_id=None, window_pct=None) -> Result:
    agent = config.agent(cfg, agent_id)
    account = budget.account_name(cfg)
    pf = budget.preflight(project, cfg, agent_id, purpose=purpose, autonomous=auto, task_id=task_id,
                          loop_id=loop_id, approved=approved, max_usd=max_usd, window_pct=window_pct,
                          dry_run=dry_run)
    if not pf.ok:
        _err(pf.message)
        return Result(pf.exit_code, refused=True, detail=pf.detail)
    run_id = pf.run_id
    session_id = pf.session_id or "00000000-0000-4000-8000-000000000000"
    argv = build_argv(cfg, agent, pf.cap, pf.level, auto, session_id, task_id)
    header = _header(task_id, run_id, pf.level, pf.cap, approved, purpose)
    if dry_run:
        print(json.dumps(argv))
        print(header.rstrip("\n"))
        return Result(0)

    before = watched_hashes(project, cfg)
    ledger_mark = _ledger_mark(project)
    win_before = budget.win_summary(budget.read_snapshot(account))
    env = child_env(os.environ, {"CREW_AGENT": agent_id, "CREW_RUN_ID": run_id, "CREW_TASK_ID": task_id,
                                 "CREW_PROJECT": project, "CREW_AUTONOMOUS": "1" if auto else "0"})
    events.write_event(project, "run.start", agent_id, session=session_id)
    started = time.time()
    child = None
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, cwd=project,
                                env=env, start_new_session=True)
    except OSError as exc:
        _err("crew: cannot start %s: %s" % (argv[0], exc))
        proc = None
    if proc is not None:
        child = _Child(proc)
        _supervise(project, child, header + task, cfg=cfg, account=account, auto=auto, window_pct=window_pct,
                   quiet=quiet)
    with _sigint_ignored():  # a Ctrl-C must not stop the run row from being written
        return _finish(project, cfg, agent, run_id, task_id, loop_id, purpose, auto, pf, session_id, account,
                       child, started, before, win_before, quiet, ledger_mark)


@contextlib.contextmanager
def _sigint_ignored():
    try:
        old = signal.signal(signal.SIGINT, signal.SIG_IGN)
    except ValueError:  # not the main thread
        yield
        return
    try:
        yield
    finally:
        signal.signal(signal.SIGINT, old if old is not None else signal.SIG_DFL)


def _supervise(project, child: _Child, prompt: str, *, cfg, account, auto, window_pct, quiet) -> None:
    """Feed the prompt, read the stream, and return only when the child has exited."""
    proc = child.proc
    done = threading.Event()

    def watch():
        while not done.wait(STOP_POLL_S):
            if config.stop_set(project):
                child.interrupt("stop")
                return
    threading.Thread(target=watch, daemon=True).start()
    try:
        try:
            proc.stdin.write(prompt)
            proc.stdin.close()
        except OSError:
            pass
        while True:
            try:
                for line in proc.stdout:
                    try:
                        _handle_line(child, line, cfg=cfg, account=account, auto=auto, window_pct=window_pct,
                                     quiet=quiet)
                    except Exception as exc:  # one bad line must not end the run
                        _err("crew: a stream line was skipped: %s" % exc)
                break
            except KeyboardInterrupt:
                child.interrupt("stop")
    except KeyboardInterrupt:
        child.interrupt("stop")
    except Exception as exc:
        _err("crew: the run loop failed, the child is stopped: %s" % exc)
        child.interrupt("internal", str(exc))
    finally:
        done.set()
        while proc.poll() is None:
            try:
                proc.wait()
            except KeyboardInterrupt:
                child.interrupt("stop")
        child.cancel()


def _finish(project, cfg, agent, run_id, task_id, loop_id, purpose, auto, pf, session_id, account, child,
            started, before, win_before, quiet, ledger_mark=None) -> Result:
    agent_id = agent["id"]
    result = child.result if child else None
    # outcome
    if result and result.get("subtype") == "success" and not result.get("is_error"):
        outcome = "ok"
    elif child and child.reason == "window":
        outcome = "window"
    elif child and child.reason == "internal":
        outcome = "error"
    elif child and child.reason == "stop":
        outcome = "stopped"
    elif result:
        outcome = "budget" if result.get("subtype") == "error_max_budget_usd" else "error"
    else:
        outcome = "crash"
    text = ((result or {}).get("result") if result and result.get("result") else None) or (child.last_text if child else "")
    crew_result = parse_crew_result(text)
    estimated = result is None
    cost = pf.cap if estimated else float(result.get("total_cost_usd") or 0.0)
    hash_changes = _diff_hashes(before, watched_hashes(project, cfg))
    if ledger_mark is not None and _ledger_changed(project, ledger_mark):
        hash_changes.append(LEDGER)
    exit_code = 1 if hash_changes and outcome == "ok" else OUTCOME_EXIT[outcome]
    row = budget.make_run_row(
        run_id=run_id, task_id=task_id, loop_id=loop_id, purpose=purpose, agent=agent_id, account=account,
        engine="claude", model=budget.agent_model(agent), effort=agent.get("effort") or _default_effort(agent),
        session_id=(result or {}).get("session_id") or session_id, cap_usd=pf.cap, autonomous=bool(auto),
        subtype=(result or {}).get("subtype"), is_error=bool((result or {}).get("is_error", True)),
        num_turns=(result or {}).get("num_turns"), cost_usd=cost, cost_estimated=estimated,
        duration_ms=(result or {}).get("duration_ms") or int((time.time() - started) * 1000),
        model_usage=_reduce_usage((result or {}).get("modelUsage")),
        subagents=((result or {}).get("subagent_stats") or {}).get("by_type") or {},
        win_before=win_before, win_after=budget.win_summary(budget.read_snapshot(account)),
        hash_changes=hash_changes,
        crew_result=crew_result, outcome=outcome, exit_code=exit_code)
    config.append_ledger(project, row)
    note = crew_result.replace("_", " ") if outcome == "ok" else outcome
    events.write_event(project, "run.end", agent_id, session=session_id, note=note)

    def log(kind, detail):
        config.append_ledger(project, budget.event_row(kind, detail, run_id=run_id, loop_id=loop_id))

    def demote(detail):
        level_now = config.effective_level(cfg, config.read_ledger(project))
        config.append_ledger(project, budget.event_row(
            "demote", detail, run_id=run_id, loop_id=loop_id, level_from=level_now,
            level_to=budget.lower_level(level_now)))

    if row["hash_changes"]:
        log("breach", "protected")
        demote("protected")
        _err("crew: protected files changed: " + ", ".join(row["hash_changes"]))
    if cost > pf.cap:
        log("breach", "budget")
    if outcome == "budget":
        events.write_event(project, "budget.over", agent_id, session=session_id, note="budget")
        if auto:
            demote("budget")
    _doctor_warnings(project)
    rows = config.read_ledger(project)
    day_spent = config.spent(rows, day=budget.today())
    _err("crew: %s $%.2f of $%.2f, task $%.2f, today $%.2f of $%.2f" % (
        outcome, cost, pf.cap, config.spent(rows, task_id=task_id), day_spent,
        budget._bnum(cfg, "per_day_usd", 10.0)))
    if outcome == "window" and child:
        _err("crew: the run was stopped for %s" % (child.reason_detail or "window"))
    return Result(exit_code, row=row, text=text, crew_result=crew_result)


def _doctor_warnings(project: str) -> None:
    doc = budget.load_doctor()
    if doc is None:
        _err("crew: doctor is not available, --changed check skipped")
        return
    try:
        for c in doc.check(project, changed_only=True):
            if c.get("level") in ("warn", "error"):
                _err("crew: doctor %s %s: %s" % (c.get("id"), c.get("path"), c.get("text")))
    except Exception as exc:
        _err("crew: doctor failed: %s" % exc)


# ---------------------------------------------------------------- crew run

def _setup(args):
    project = config.find_project(os.getcwd())
    if project is None:
        _err("crew: not inside a crew project (no .crew/crew.json above the current folder)")
        return None, None, 8
    cfg, errors = config.load(project)
    if errors:
        _err("crew: crew.json has errors: " + "; ".join(errors))
        return None, None, 7
    return project, cfg, 0


def run_run(args) -> int:
    project, cfg, code = _setup(args)
    if project is None:
        return code
    task = getattr(args, "task", None)
    if getattr(args, "file", None):
        try:
            with open(args.file, "r", encoding="utf-8") as fh:
                task = fh.read()
        except OSError as exc:
            _err("crew: cannot read the task file: %s" % exc)
            return 2
    if not task or not task.strip():
        _err("crew: give the task text or --file")
        return 2
    agent_id = getattr(args, "agent", None) or cfg["lead"]
    agent = config.agent(cfg, agent_id)
    if agent is None:
        _err("crew: unknown agent: %s" % agent_id)
        return 2
    if agent.get("engine", "claude") != "claude":
        _err("crew: only the claude engine is supported")
        return 2
    res = execute(project, cfg, task=task, agent_id=agent_id,
                  task_id=getattr(args, "task_id", None) or budget.new_id("t"),
                  approved=bool(getattr(args, "approved", False)), auto=bool(getattr(args, "auto", False)),
                  max_usd=getattr(args, "max_usd", None), quiet=bool(getattr(args, "quiet", False)),
                  dry_run=bool(getattr(args, "dry_run", False)), purpose="task")
    if res.row is not None:
        if getattr(args, "json", False):
            print(json.dumps(res.row))
        elif res.text:
            print(res.text)
    return res.exit_code


# ---------------------------------------------------------------- crew loop (11.1, 13.6)

OPEN_LINE = re.compile(r"^- \[ \] (.+)$")


def next_backlog_line(project: str) -> Optional[str]:
    try:
        with open(os.path.join(project, ".crew", "BACKLOG.md"), "r", encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    for line in lines:
        m = OPEN_LINE.match(line)
        if m and not m.group(1).rstrip().endswith("(blocked)"):
            return m.group(1)
    return None


def mark_blocked(project: str, goal: str) -> None:
    path = os.path.join(project, ".crew", "BACKLOG.md")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return
    for i, line in enumerate(lines):
        if line == "- [ ] " + goal:  # still open: the lead did not mark it done
            lines[i] = line + " (blocked)"
            break
    else:
        return
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    os.replace(tmp, path)


def _deadline(until: Optional[str]) -> Optional[float]:
    if not until:
        return None
    m = re.fullmatch(r"([01]?\d|2[0-3]):([0-5]\d)", until.strip())
    if not m:
        raise ValueError("--until must be HH:MM")
    now = datetime.now()
    t = now.replace(hour=int(m.group(1)), minute=int(m.group(2)), second=0, microsecond=0)
    if t <= now:
        t += timedelta(days=1)
    return t.timestamp()


def run_loop(args) -> int:
    project, cfg, code = _setup(args)
    if project is None:
        return code
    goal = getattr(args, "goal", None)
    backlog, improve = bool(getattr(args, "backlog", False)), bool(getattr(args, "improve", False))
    if improve:
        _err("crew: --improve is not in this build")
        return 2
    if bool(goal) == backlog:
        _err("crew: give one GOAL or --backlog")
        return 2
    try:
        deadline = _deadline(getattr(args, "until", None))
    except ValueError as exc:
        _err("crew: %s" % exc)
        return 2
    max_iter = getattr(args, "max_iterations", None)
    max_iter = 5 if max_iter is None else max_iter
    window_pct = getattr(args, "window", None)
    if max_iter < 1:
        _err("crew: --max-iterations must be 1 or more")
        return 2
    if window_pct is not None and not 1 <= window_pct <= 100:
        _err("crew: --window must be from 1 to 100")
        return 2
    dry_run = bool(getattr(args, "dry_run", False))
    level = config.effective_level(cfg, config.read_ledger(project))
    if int(level[1:]) < 4:
        _err("crew: refused (level): crew loop needs L4 or L5, the level is " + level)
        return 4
    if level == "L4" and deadline is None and max_iter > 10:
        _err("crew: refused (level): at L4 use --until or --max-iterations of at most 10")
        return 4
    max_usd = getattr(args, "max_usd", None)
    if max_usd is not None:  # --max-usd lowers per_loop_usd only
        cfg["budget"]["per_loop_usd"] = min(budget._bnum(cfg, "per_loop_usd", 5.0), float(max_usd))
    lead = cfg["lead"]
    loop_id = budget.new_id("l")
    if dry_run:
        first = goal or next_backlog_line(project)
        if first is None:
            _err("crew: backlog is empty")
            return 0
        return execute(project, cfg, task=first, agent_id=lead, task_id=budget.new_id("t"), auto=True,
                       dry_run=True, purpose="loop", loop_id=loop_id, window_pct=window_pct).exit_code
    config.append_ledger(project, budget.event_row("loop.start", "manual", loop_id=loop_id))
    events.write_event(project, "loop.start", lead)

    state = {"reason": "iterations", "code": 0}

    def end(reason, code=0):
        state["reason"], state["code"] = reason, code

    flat = 0
    n = 0
    stopping = False
    while not stopping:
        if config.stop_set(project):
            end("stop", 3)
            break
        if deadline is not None and time.time() >= deadline:
            end("deadline")
            break
        if n >= max_iter:
            end("iterations")
            break
        lvl = config.effective_level(cfg, config.read_ledger(project))
        if int(lvl[1:]) < 4:
            end("level", 4)
            break
        text = goal if goal else next_backlog_line(project)  # before the probe: an empty backlog costs nothing
        if text is None:
            end("backlog-empty")
            break
        account = budget.account_name(cfg)
        state_w = budget.window_state(budget.trusted_snapshot(budget.read_snapshot(account)),
                                      budget._bnum(cfg, "snapshot_max_age_auto_s", 120))
        if any(state_w[w]["unknown"] for w in budget.WINDOWS):
            budget.run_probe(project, cfg, loop_id)
        n += 1
        res = execute(project, cfg, task=text, agent_id=lead, task_id=budget.new_id("t"), auto=True,
                      quiet=bool(getattr(args, "quiet", False)), purpose="loop", loop_id=loop_id,
                      window_pct=window_pct)
        if res.refused:
            end(res.detail, res.exit_code)
            break
        if res.text:
            print(res.text)
        row = res.row
        if backlog and res.crew_result in ("blocked", "needs_approval"):
            mark_blocked(project, text)
        if row["outcome"] == "stopped":
            end("stop", 130)
            break
        if row["outcome"] == "window":
            end("window", 6)
            break
        if row["hash_changes"]:
            end("protected", 1)
            break
        if _doctor_failed(project):
            rows = config.read_ledger(project)
            cur = config.effective_level(cfg, rows)
            config.append_ledger(project, budget.event_row("demote", "doctor", run_id=row["run_id"],
                                                           loop_id=loop_id, level_from=cur,
                                                           level_to=budget.lower_level(cur)))
            end("doctor", 7)
            break
        flat = 0 if row["crew_result"] == "changed" else flat + 1
        if flat >= 3:
            end("plateau")
            break
    reason = state["reason"]
    config.append_ledger(project, budget.event_row("loop.end", reason if reason != "doctor" else "doctor",
                                                   loop_id=loop_id))
    events.write_event(project, "loop.end", lead, note=LOOP_NOTE.get(reason))
    _err("crew: loop ended (%s) after %d iteration%s" % (reason, n, "" if n == 1 else "s"))
    return state["code"]


def _doctor_failed(project: str) -> bool:
    doc = budget.load_doctor()
    if doc is None:
        _err("crew: doctor is not available, end-of-iteration check skipped")
        return False
    try:
        bad = [c for c in doc.check(project) if c.get("level") == "error"]
    except Exception as exc:
        _err("crew: doctor failed: %s" % exc)
        return False
    for c in bad:
        _err("crew: doctor %s %s: %s" % (c.get("id"), c.get("path"), c.get("text")))
    return bool(bad)
