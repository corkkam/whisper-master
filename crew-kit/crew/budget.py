"""Crew budget: preflight, plan window snapshots, `crew budget` and `crew statusline`.

The plan window (percent of the 5-hour and the weekly limit) is the main budget.
Dollar caps are a per-run safety stop. See spec section 9 and build-notes.
"""
from __future__ import annotations

import contextlib
import json
import os
import secrets
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

from crew import config, events

WINDOWS = ("five_hour", "seven_day")
# "allowed_warning" is a real status of the stream. It is not overage.
OK_STATUS = (None, "allowed", "allowed_warning")
DEFAULT_MAX_BUDGET = {"lead": 3.0, "component": 2.0}
DEFAULT_MODEL = {"lead": "opus", "helper": "haiku"}
PROBE_PROMPT = "Reply with the word ok."


# ---------------------------------------------------------------- small helpers

def new_id(kind: str) -> str:
    """Run id `r-`, loop id `l-` or task id `t-` (spec 13.4). Local time."""
    stamp = time.strftime("%Y%m%d-%H%M%S") if kind in ("r", "l") else time.strftime("%Y%m%d-%H%M")
    return "%s-%s-%s" % (kind, stamp, secrets.token_hex(2))


def load_doctor():
    """The doctor module, or None when it is not built yet. Tests patch this."""
    try:
        from crew import doctor
        return doctor
    except ImportError:
        return None


def claude_bin() -> str:
    return os.environ.get("CREW_CLAUDE_BIN") or "claude"


def account_name(cfg: dict) -> str:
    try:
        return config.account(cfg or {})
    except Exception:
        return "default"


def agent_model(agent: dict) -> str:
    return agent.get("model") or DEFAULT_MODEL.get(agent.get("role"), "sonnet")


def agent_cap(agent: dict) -> float:
    default = DEFAULT_MAX_BUDGET.get(agent.get("role"), 0.50)
    return _num(agent.get("max_budget_usd"), default)


def _num(value, default: float) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return float(default)


def _bnum(cfg: dict, key: str, default: float) -> float:
    return _num((cfg.get("budget") or {}).get(key), default)


def today() -> str:
    return datetime.now().date().isoformat()


def _epoch(ts) -> Optional[float]:
    try:
        return datetime.strptime(str(ts)[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def lower_level(level: str) -> str:
    return "L%d" % max(0, int(level[1:]) - 1)


def append_unlocked(project: str, row: dict) -> None:
    """Append a ledger row. The caller already holds ledger_lock (flock is not re-entrant)."""
    out = {"t": row["t"], "v": 1, "ts": row.get("ts") or config.utc_ts()}
    out.update({k: v for k, v in row.items() if k not in out})
    data = (json.dumps(out, separators=(",", ":")) + "\n").encode("utf-8")
    fd = os.open(os.path.join(project, ".crew", "ledger.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)


def event_row(kind: str, detail: str, *, run_id=None, loop_id=None, level_from=None, level_to=None) -> dict:
    return {"t": "event", "kind": kind, "detail": detail, "run_id": run_id, "loop_id": loop_id,
            "level_from": level_from, "level_to": level_to}


def make_run_row(**f) -> dict:
    """A run row with exactly the keys of spec 9.1, in order."""
    keys = ("run_id", "task_id", "loop_id", "purpose", "agent", "account", "engine", "model", "effort",
            "session_id", "cap_usd", "autonomous", "subtype", "is_error", "num_turns", "cost_usd",
            "cost_estimated", "duration_ms", "model_usage", "subagents", "win_before", "win_after",
            "hash_changes", "crew_result", "outcome", "exit_code")
    row = {"t": "run"}
    for k in keys:
        row[k] = f.get(k)
    return row


# ---------------------------------------------------------------- window snapshot (9.2)

def snapshot_path(account: str) -> str:
    safe = "".join(c if (c.isalnum() or c in "._-") else "_" for c in account) or "default"
    return os.path.join(config.crew_home(), "windows", safe + ".json")


def read_snapshot(account: str):
    try:
        with open(snapshot_path(account), "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _pct_window(pct, resets):
    if pct is None:
        return None
    try:
        return {"used_percentage": round(float(pct), 2), "resets_at": resets}
    except (TypeError, ValueError):
        return None


def write_snapshot(account: str, info: dict, source: str) -> None:
    """info is `rate_limits` of the status line, or `rate_limit_info` of a stream event."""
    info = info or {}
    snap = {"v": 1, "account": account, "captured_at": config.utc_ts(), "source": source,
            "status": None, "is_using_overage": None, "overage_status": None,
            "five_hour": None, "seven_day": None}
    if source == "stream":
        snap["status"] = info.get("status")
        snap["is_using_overage"] = info.get("isUsingOverage")
        snap["overage_status"] = info.get("overageStatus")
        unified = info.get("unifiedWindows") or {}
        for w in WINDOWS:
            d = unified.get(w)
            if isinstance(d, dict) and d.get("utilization") is not None:
                try:
                    snap[w] = _pct_window(float(d["utilization"]) * 100, d.get("resetsAt"))
                except (TypeError, ValueError):
                    pass
    else:
        for w in WINDOWS:
            d = info.get(w)
            if isinstance(d, dict):
                snap[w] = _pct_window(d.get("used_percentage"), d.get("resets_at"))
    if source != "stream":
        # The status line has no overage data. Keep a live overage state from the last snapshot.
        old = read_snapshot(account)
        # Keep the last stream reading too: an autonomous preflight trusts only that one.
        if isinstance(old, dict):
            snap["stream"] = old if old.get("source") == "stream" else old.get("stream")
        if overage_active(old):
            snap["status"], snap["is_using_overage"] = old.get("status"), old.get("is_using_overage")
            snap["overage_status"] = old.get("overage_status")
    path = snapshot_path(account)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(snap, fh)
    os.replace(tmp, path)


def trusted_snapshot(snap):
    """The snapshot that crew run or a probe wrote from a rate_limit_event, or None.

    An agent can feed `crew statusline` any numbers, so an autonomous run reads only this one.
    """
    if not isinstance(snap, dict):
        return None
    if snap.get("source") == "stream":
        return snap
    s = snap.get("stream")
    return s if isinstance(s, dict) and s.get("source") == "stream" else None


def window_state(snap, max_age_s: float, now: Optional[float] = None) -> dict:
    """For each window: {"pct": float|None, "resets_at", "unknown": bool}."""
    now = time.time() if now is None else now
    taken = _epoch(snap.get("captured_at")) if snap else None
    # a captured_at in the future is not fresh: it would never go stale
    stale = taken is None or now - taken > max_age_s or taken > now + 60
    out = {}
    for w in WINDOWS:
        d = (snap or {}).get(w)
        d = d if isinstance(d, dict) else {}
        pct, reset = d.get("used_percentage"), d.get("resets_at")
        past = isinstance(reset, (int, float)) and reset < now
        out[w] = {"pct": pct, "resets_at": reset, "unknown": stale or pct is None or past}
    return out


def on_overage(snap) -> bool:
    return bool(snap) and (snap.get("is_using_overage") is True or snap.get("status") not in OK_STATUS)


def _overage_over(snap, now: float) -> bool:
    """True only when the snapshot has a reset time and every reset time is in the past."""
    resets = [d.get("resets_at") for d in (snap.get(w) for w in WINDOWS) if isinstance(d, dict)]
    resets = [r for r in resets if isinstance(r, (int, float))]
    return bool(resets) and all(r < now for r in resets)


def overage_active(snap, now: Optional[float] = None) -> bool:
    """The snapshot shows overage and no window has reset since. A stale snapshot still counts."""
    return on_overage(snap) and not _overage_over(snap, time.time() if now is None else now)


def limits(cfg: dict, window_pct=None) -> dict:
    five = window_pct if window_pct is not None else _bnum(cfg, "max_five_hour_pct", 90)
    return {"five_hour": float(five), "seven_day": _bnum(cfg, "max_seven_day_pct", 80)}


def at_limit(snap, cfg: dict, window_pct=None) -> list:
    lim = limits(cfg, window_pct)
    out = []
    for w in WINDOWS:
        d = (snap or {}).get(w)
        pct = d.get("used_percentage") if isinstance(d, dict) else None
        if pct is not None and pct >= lim[w]:
            out.append(w)
    return out


def win_summary(snap):
    """The win_before and win_after value of a run row."""
    if not snap:
        return None
    return {w: (snap[w].get("used_percentage") if isinstance(snap.get(w), dict) else None) for w in WINDOWS}


# ---------------------------------------------------------------- preflight (9.3)

@dataclass
class Preflight:
    ok: bool
    exit_code: int = 0
    cap: float = 0.0
    detail: str = ""
    level: str = "L0"
    message: str = ""
    run_id: Optional[str] = None
    session_id: Optional[str] = None
    remaining: float = 0.0


def _shim_problem() -> Optional[str]:
    shim = os.path.join(config.crew_home(), "bin", "crew")
    if not os.access(shim, os.X_OK):
        return "the shim is missing: %s (run crew install)" % shim
    import crew
    want = "crew " + getattr(crew, "__version__", "")
    try:
        got = subprocess.run([shim, "--version"], capture_output=True, text=True, timeout=15).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "the shim does not run: %s" % shim
    if got != want:
        return "the shim prints %r, expected %r (run crew install --force)" % (got, want)
    return None


def _doctor_problem(project: str) -> Optional[str]:
    doc = load_doctor()
    if doc is None:
        sys.stderr.write("crew: doctor is not available, D11 check skipped\n")
        return None
    try:
        for c in doc.check(project):
            if c.get("id") == "D11" and c.get("level") == "error":
                return "doctor D11: %s" % c.get("text")
    except Exception as exc:  # a doctor bug must not stop a run; say so
        sys.stderr.write("crew: doctor failed, D11 check skipped (%s)\n" % exc)
    return None


def preflight(project: str, cfg: dict, agent_id: str, *, purpose: str = "task", autonomous: bool = False,
              task_id=None, loop_id=None, approved: bool = False, max_usd=None, window_pct=None,
              dry_run: bool = False) -> Preflight:
    """Steps 0 to 8 of spec 9.3. `dry_run` skips step 0 and every write."""
    agent = config.agent(cfg, agent_id) or {}
    lead = cfg.get("lead") or agent_id

    def refuse(code, detail, msg, level="L0", budget_over=False):
        if not dry_run:
            config.append_ledger(project, event_row("refuse", detail, loop_id=loop_id))
            if budget_over:
                events.write_event(project, "budget.over", lead, note="budget")
        return Preflight(False, code, 0.0, detail, level, "crew: refused (%s): %s" % (detail, msg))

    # 0. the shim and D11
    if not dry_run:
        problem = _shim_problem() or _doctor_problem(project)
        if problem:
            return refuse(7, "doctor", problem)
    # 1. STOP
    if config.stop_set(project):
        return refuse(3, "stop", "a STOP file is set")
    # 2. level
    level = config.effective_level(cfg, config.read_ledger(project))
    n = int(level[1:])
    if n == 0:
        return refuse(4, "level", "the autonomy level is L0", level)
    if autonomous and n < 4:
        return refuse(4, "level", "an autonomous run needs L4 or more, the level is " + level, level)

    run_id, session_id = new_id("r"), None
    cap = remaining = 0.0
    refusal = None
    with (contextlib.nullcontext() if dry_run else config.ledger_lock(project)):
        rows = config.read_ledger(project)
        day = today()
        day_spent = config.spent(rows, day=day)
        task_spent = config.spent(rows, task_id=task_id) if task_id else 0.0
        loop_spent = config.spent(rows, loop_id=loop_id) if loop_id else 0.0
        # 4. remaining
        terms = [(agent_cap(agent), "task-cap")]
        if max_usd is not None:
            terms.append((float(max_usd), "task-cap"))
        terms.append((_bnum(cfg, "per_task_usd", 3.0) - task_spent, "task-cap"))
        if loop_id:
            terms.append((_bnum(cfg, "per_loop_usd", 5.0) - loop_spent, "loop-cap"))
        terms.append((_bnum(cfg, "per_day_usd", 10.0) - day_spent, "day-cap"))
        remaining, which = min(terms, key=lambda t: t[0])
        # 5. cap
        reserves = (cfg.get("budget") or {}).get("call_reserve_usd") or {}
        reserve = _num(reserves.get(agent_model(agent), reserves.get("default")), 0.3)
        cap = round(min(remaining * _bnum(cfg, "cap_headroom", 1.0), remaining - reserve), 2)
        if cap < 0.05:
            refusal = (5, which, "no budget left (%s, remaining $%.2f, reserve $%.2f)" % (which, remaining, reserve), True)
        else:
            refusal = _window_refusal(cfg, rows, autonomous, level, window_pct)
        # 8. reserve, session map
        if refusal is None and not dry_run:
            session_id = str(uuid.uuid4())
            append_unlocked(project, {"t": "reserve", "run_id": run_id, "task_id": task_id, "loop_id": loop_id,
                                      "agent": agent_id, "cap_usd": cap})
            config.write_session(session_id, {
                "v": 1, "session": session_id, "agent": agent_id, "project": project, "task_id": task_id,
                "run_id": run_id, "purpose": purpose, "autonomous": bool(autonomous),
                "approved": bool(approved), "turns": 0, "created_at": config.utc_ts()})
    if refusal:
        code, detail, msg = refusal[0], refusal[1], refusal[2]
        return refuse(code, detail, msg, level, budget_over=len(refusal) > 3 and refusal[3])
    return Preflight(True, 0, cap, "", level, "", run_id, session_id, remaining)


def _window_refusal(cfg, rows, autonomous, level, window_pct):
    """Steps 6 and 7. Returns (exit, detail, message) or None."""
    b = cfg.get("budget") or {}
    account = account_name(cfg)
    snap = read_snapshot(account)
    age = _bnum(cfg, "snapshot_max_age_auto_s" if autonomous else "snapshot_max_age_s", 600)
    state = window_state(snap, age)
    # Overage holds until a window reset passes. Age alone does not clear it ($0 rule).
    if overage_active(snap):
        return (6, "overage", "the account is on overage; after the window resets, "
                              "run crew budget --probe to refresh the window")
    if not autonomous:
        return None
    snap = trusted_snapshot(snap)
    state = window_state(snap, age)
    if not b.get("overage_guard_verified") and int(level[1:]) >= 4:
        return (6, "unverified", "overage_guard_verified is false")
    if not b.get("allow_unknown_window") and any(state[w]["unknown"] for w in WINDOWS):
        return (6, "unknown-window", "the plan window is unknown (run crew budget --probe)")
    hit = at_limit(snap, cfg, window_pct)
    if hit:
        return (6, "window", "a window is at its limit: " + ", ".join(hit))
    return None


# ---------------------------------------------------------------- probe

def run_probe(project: str, cfg: dict, loop_id=None) -> bool:
    """One tiny haiku call. It writes the snapshot and a run row with purpose "probe".

    It runs no preflight and holds no reserve. Its cost is the $0.02 cap, counted in the ledger.
    It does not run on overage or at L0, so it never adds overage spend.
    """
    from crew import runner
    snap = read_snapshot(account_name(cfg))
    if overage_active(snap):
        sys.stderr.write("crew: probe skipped: the account is on overage until a window resets\n")
        return False
    if config.effective_level(cfg, config.read_ledger(project)) == "L0":
        sys.stderr.write("crew: probe skipped: the autonomy level is L0\n")
        return False
    argv = [claude_bin(), "-p", "--model", "haiku", "--max-budget-usd", "0.02", "--output-format", "stream-json",
            "--verbose", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
    run_id, account = new_id("r"), account_name(cfg)
    env = runner.child_env(os.environ, {"CREW_PROJECT": project, "CREW_RUN_ID": run_id, "CREW_AUTONOMOUS": "0"})
    win_before = win_summary(read_snapshot(account))
    started, result = time.time(), None
    try:
        out = subprocess.run(argv, input=PROBE_PROMPT, capture_output=True, text=True, timeout=180,
                             cwd=project, env=env).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        sys.stderr.write("crew: probe failed: %s\n" % exc)
        out = ""
    for line in out.splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("type") == "rate_limit_event":
            write_snapshot(account, obj.get("rate_limit_info") or {}, "stream")
        elif obj.get("type") == "result":
            result = obj
    ok = bool(result) and result.get("subtype") == "success"
    cost = _num(result.get("total_cost_usd"), 0.02) if result else 0.02
    config.append_ledger(project, make_run_row(
        run_id=run_id, task_id=None, loop_id=loop_id, purpose="probe", agent=cfg.get("lead"), account=account,
        engine="claude", model="haiku", effort=None, session_id=(result or {}).get("session_id"), cap_usd=0.02,
        autonomous=False, subtype=(result or {}).get("subtype"), is_error=not ok,
        num_turns=(result or {}).get("num_turns"), cost_usd=cost, cost_estimated=result is None,
        duration_ms=int((time.time() - started) * 1000), model_usage={}, subagents={},
        win_before=win_before, win_after=win_summary(read_snapshot(account)), hash_changes=[],
        crew_result=None, outcome="ok" if ok else "error", exit_code=0 if ok else 1))
    return ok


# ---------------------------------------------------------------- crew budget

def _age(snap, now):
    t = _epoch(snap.get("captured_at")) if snap else None
    return None if t is None else int(now - t)


def run_budget(args) -> int:
    project = config.find_project(os.getcwd())
    if project is None:
        sys.stderr.write("crew: not inside a crew project\n")
        return 8
    cfg, errors = config.load(project)
    if errors:
        sys.stderr.write("crew: %s\n" % "; ".join(errors))
        return 7
    if getattr(args, "probe", False):
        if config.stop_set(project):
            sys.stderr.write("crew: a STOP file is set, probe skipped\n")
        elif not run_probe(project, cfg) and not overage_active(read_snapshot(account_name(cfg))):
            sys.stderr.write("crew: the probe did not finish ok\n")
    account = account_name(cfg)
    snap, now = read_snapshot(account), time.time()
    rows = config.read_ledger(project)
    state = window_state(snap, _bnum(cfg, "snapshot_max_age_s", 600), now)
    lim = limits(cfg)
    task_id = getattr(args, "task", None)
    out = {
        "account": account,
        "level": config.effective_level(cfg, rows),
        "configured_level": (cfg.get("autonomy") or {}).get("level"),
        "stop": {"project": os.path.exists(os.path.join(project, ".crew", "STOP")),
                 "global": os.path.exists(os.path.join(config.crew_home(), "STOP"))},
        "windows": {w: {"used_pct": state[w]["pct"], "limit_pct": lim[w], "resets_at": state[w]["resets_at"],
                        "unknown": state[w]["unknown"], "age_s": _age(snap, now)} for w in WINDOWS},
        "overage": on_overage(snap),
        "today": {"spent_usd": round(config.spent(rows, day=today()), 4),
                  "cap_usd": _bnum(cfg, "per_day_usd", 10.0)},
    }
    if task_id:
        out["task"] = {"id": task_id, "spent_usd": round(config.spent(rows, task_id=task_id), 4),
                       "cap_usd": _bnum(cfg, "per_task_usd", 3.0)}
    n = getattr(args, "runs", None)
    if n:
        out["runs"] = [r for r in rows if r.get("t") == "run"][-int(n):]
    if getattr(args, "json", False):
        print(json.dumps(out, indent=2))
        return 0
    print("account %s, level %s (configured %s), STOP: %s" % (
        account, out["level"], out["configured_level"],
        "project" if out["stop"]["project"] else "global" if out["stop"]["global"] else "not set"))
    for w, label in (("five_hour", "5-hour window"), ("seven_day", "7-day window")):
        d = out["windows"][w]
        if d["used_pct"] is None:
            print("%s: unknown" % label)
        else:
            print("%s: %.1f%% of %.0f%%%s%s" % (label, d["used_pct"], d["limit_pct"],
                                               ", age %ss" % d["age_s"] if d["age_s"] is not None else "",
                                               " (unknown: stale or reset)" if d["unknown"] else ""))
    print("overage: %s" % ("yes" if out["overage"] else "no"))
    print("today: $%.2f of $%.2f" % (out["today"]["spent_usd"], out["today"]["cap_usd"]))
    if task_id:
        print("task %s: $%.2f of $%.2f" % (task_id, out["task"]["spent_usd"], out["task"]["cap_usd"]))
    for r in out.get("runs", []):
        print("run %s %s %s $%s" % (r.get("run_id"), r.get("agent"), r.get("outcome"), r.get("cost_usd")))
    return 0


# ---------------------------------------------------------------- crew statusline

def run_statusline(args) -> int:
    if getattr(args, "install", False):
        print(json.dumps({"statusLine": {"type": "command", "command": '"$HOME"/.crew/bin/crew statusline'}}, indent=2))
        return 0
    try:
        raw = sys.stdin.read()
        try:
            data = json.loads(raw)
        except ValueError:
            data = {}
        data = data if isinstance(data, dict) else {}
        limits_ = data.get("rate_limits")
        # A crew run must not refresh the plan window with numbers it chose (review kit-safety 10).
        crew_child = os.environ.get("CREW_AGENT") or os.environ.get("CREW_RUN_ID")
        if isinstance(limits_, dict) and not crew_child:
            project = config.find_project(data.get("cwd") or os.getcwd())
            cfg = config.load(project)[0] if project else {}
            write_snapshot(account_name(cfg), limits_, "statusline")
        nxt = os.environ.get("CREW_STATUSLINE_NEXT")
        if nxt:
            out = subprocess.run(["/bin/sh", "-c", nxt], input=raw, capture_output=True, text=True, timeout=10).stdout
            sys.stdout.write(out)
        else:
            def pct(w):
                d = (limits_ or {}).get(w) if isinstance(limits_, dict) else None
                v = d.get("used_percentage") if isinstance(d, dict) else None
                return "-" if v is None else "%d" % round(float(v))
            print("crew 5h %s%% 7d %s%%" % (pct("five_hour"), pct("seven_day")))
    except Exception:
        pass  # a status line must never fail
    return 0
