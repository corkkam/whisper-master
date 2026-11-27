"""A fake `claude` for the Crew tests, plus the fixture helpers they share.

As a script it prints stream-json chosen by FAKE_CLAUDE_SCENARIO:
success, budget, crash, rate_limit, overage, slow, subagents, stubborn, badblock.
stubborn ignores SIGINT and SIGTERM. badblock sends a content block that is not an object.
It appends one JSON line (argv, env, stdin) to the file in FAKE_CLAUDE_RECORD.

Other variables: FAKE_CLAUDE_CRESULT (changed), FAKE_CLAUDE_COST, FAKE_CLAUDE_UTIL5 and
FAKE_CLAUDE_UTIL7 (a fraction), FAKE_CLAUDE_TOUCH (a file to append to), FAKE_CLAUDE_WAIT (seconds).
"""
from __future__ import annotations

import json
import os
import signal
import stat
import sys
import threading
import time

# ---------------------------------------------------------------- the fake itself


def _emit(obj) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def _rate_event(util5, util7, overage=False):
    now = int(time.time())
    return {"type": "rate_limit_event", "rate_limit_info": {
        "status": "rejected" if overage else "allowed", "resetsAt": now + 3600, "rateLimitType": "five_hour",
        "overageStatus": "allowed" if overage else None, "isUsingOverage": overage,
        "unifiedWindows": {
            "five_hour": {"utilization": util5, "resetsAt": now + 3600, "status": "allowed"},
            "seven_day": {"utilization": util7, "resetsAt": now + 86400, "status": "allowed"}}}}


def _text(text):
    return {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}, "parent_tool_use_id": None}


def _bash(command):
    return {"type": "assistant", "parent_tool_use_id": None,
            "message": {"content": [{"type": "tool_use", "id": "tu1", "name": "Bash", "input": {"command": command}}]}}


def _result(subtype, text, cost, session, **extra):
    r = {"type": "result", "subtype": subtype, "is_error": subtype != "success", "num_turns": 3,
         "duration_ms": 1234, "total_cost_usd": cost, "session_id": session, "result": text}
    r.update(extra)
    if subtype == "error_max_budget_usd":
        r.pop("result")
    return r


def main() -> int:
    argv = sys.argv[1:]
    stdin = sys.stdin.read()
    rec = os.environ.get("FAKE_CLAUDE_RECORD")
    if rec:
        env = {}
        for k, v in os.environ.items():
            if k.startswith(("CLAUDE", "CREW", "ANTHROPIC")):
                env[k] = "***" if any(w in k for w in ("TOKEN", "KEY", "SECRET")) else v
        with open(rec, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"argv": argv, "env": env, "stdin": stdin}) + "\n")
    scenario = os.environ.get("FAKE_CLAUDE_SCENARIO", "success")
    cresult = os.environ.get("FAKE_CLAUDE_CRESULT", "changed")
    cost = float(os.environ.get("FAKE_CLAUDE_COST", "0.84"))
    u5 = float(os.environ.get("FAKE_CLAUDE_UTIL5", "0.02"))
    u7 = float(os.environ.get("FAKE_CLAUDE_UTIL7", "0.12"))
    session = argv[argv.index("--session-id") + 1] if "--session-id" in argv else "fake-session"
    touch = os.environ.get("FAKE_CLAUDE_TOUCH")
    if touch:
        with open(touch, "a", encoding="utf-8") as fh:
            fh.write("\n")
    _emit({"type": "system", "subtype": "init", "session_id": session})
    final = 'All done.\n{"crew_result": "%s", "task_id": null, "branch": null, "pr": null}' % cresult
    if scenario == "crash":
        sys.stderr.write("fake claude: boom\n")
        return 3
    if scenario in ("slow", "overage"):
        stop = threading.Event()
        signal.signal(signal.SIGINT, lambda *_: stop.set())
        _emit(_rate_event(u5, u7, overage=scenario == "overage"))
        _emit(_text("working"))
        stop.wait(float(os.environ.get("FAKE_CLAUDE_WAIT", "30")))
        return 130 if stop.is_set() else 0
    if scenario == "stubborn":
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        _emit(_rate_event(u5, u7))
        _emit(_text("working"))
        time.sleep(float(os.environ.get("FAKE_CLAUDE_WAIT", "30")))
        return 0
    if scenario == "badblock":
        _emit({"type": "assistant", "parent_tool_use_id": None, "message": {"content": ["text", 5, None]}})
    if scenario == "subagents":
        _emit({"type": "system", "subtype": "task_started", "subagent_type": "pm", "task_id": "a1"})
        _emit({"type": "system", "subtype": "task_started", "subagent_type": "c-api", "task_id": "a2"})
        _emit({"type": "system", "subtype": "task_started", "subagent_type": "general-purpose", "task_id": "a3"})
        _emit(_bash('crew emit huddle.start --agent nova --task t1 --agents pm,qa'))
        _emit(_bash('"$HOME"/.crew/bin/crew emit huddle.end --agent nova --agents pm,qa'))
        _emit(_bash("ls -la"))
    _emit(_rate_event(u5, u7))
    if scenario == "budget":
        _emit(_text("partial answer"))
        _emit(_result("error_max_budget_usd", "", float(os.environ.get("FAKE_CLAUDE_COST", "2.05")), session))
        return 1
    _emit(_text(final))
    extra = {"modelUsage": {"claude-opus-5-5": {"costUSD": cost, "inputTokens": 10, "outputTokens": 99,
                                                "contextWindow": 1000000}},
             "subagent_stats": {"by_type": {"pm": 1, "c-api": 1} if scenario == "subagents" else {}}}
    _emit(_result("success", final, cost, session, **extra))
    return 0


# ---------------------------------------------------------------- fixture helpers for the tests

def make_home(root: str) -> str:
    """A CREW_HOME with a shim that prints the kit version."""
    from crew import __version__
    home = os.path.join(root, "crewhome")
    os.makedirs(os.path.join(home, "bin"))
    shim = os.path.join(home, "bin", "crew")
    with open(shim, "w") as fh:
        fh.write('#!/bin/sh\necho "crew %s"\n' % __version__)
    os.chmod(shim, os.stat(shim).st_mode | stat.S_IXUSR)
    return home


def make_wrapper(root: str) -> str:
    """CREW_CLAUDE_BIN: a script that runs this file with the current Python."""
    path = os.path.join(root, "claude")
    with open(path, "w") as fh:
        fh.write('#!/bin/sh\nexec "%s" "%s" "$@"\n' % (sys.executable, os.path.abspath(__file__)))
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    return path


def make_project(root: str, level: str = "L3", budget=None, autonomy=None) -> str:
    project = os.path.join(root, "proj")
    os.makedirs(os.path.join(project, ".crew"))
    cfg = {
        "version": 1, "project": {"name": "demo", "public_paths": []}, "lead": "nova",
        "agents": [
            {"id": "nova", "role": "lead", "name": "Nova", "model": "opus", "effort": "high", "max_budget_usd": 3.0},
            {"id": "pm", "role": "pm", "name": "Paige"},
            {"id": "qa", "role": "qa", "name": "Quinn"},
            {"id": "c-api", "role": "component", "name": "Api", "component_dir": "api", "paths": ["api/"]}],
        "budget": dict(budget or {}),
        "autonomy": {"level": level, "set_at": "2020-01-01T00:00:00+00:00", "expires_at": None, "set_by": "owner"},
    }
    if level in ("L4", "L5"):
        cfg["autonomy"]["set_at"] = _now_iso()
        cfg["autonomy"]["expires_at"] = _later_iso(days=3)
        cfg["budget"].setdefault("overage_guard_verified", True)
    if autonomy:
        cfg["autonomy"].update(autonomy)
    with open(os.path.join(project, ".crew", "crew.json"), "w") as fh:
        json.dump(cfg, fh, indent=2)
    with open(os.path.join(project, ".crew", "BACKLOG.md"), "w") as fh:
        fh.write("# Backlog\n- [ ] first task\n- [ ] second task\n")
    return project


def _now_iso():
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _later_iso(days):
    from datetime import datetime, timedelta, timezone
    return (datetime.now(timezone.utc) + timedelta(days=days)).isoformat(timespec="seconds")


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def write_text(path: str, text: str = "") -> None:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def read_events(home: str) -> list:
    return [json.loads(x) for x in read_text(os.path.join(home, "events.jsonl")).splitlines() if x.strip()]


def read_record(path: str) -> list:
    with open(path, "r", encoding="utf-8") as fh:
        return [json.loads(x) for x in fh if x.strip()]


class FakeDoctor:
    """Stands in for crew.doctor so a test does not depend on the real checks."""
    problems: list = []

    @classmethod
    def check(cls, project, changed_only=False):
        return list(cls.problems)


def case_base():
    """The shared TestCase base: temp CREW_HOME, project, fake claude, patched doctor and kit folder."""
    import shutil
    import tempfile
    import unittest
    from unittest import mock

    class CrewCase(unittest.TestCase):
        level = "L3"
        budget = None

        def setUp(self):
            from crew import budget as b, runner
            self.root = os.path.realpath(tempfile.mkdtemp(prefix="crew-test-"))
            self.addCleanup(shutil.rmtree, self.root, True)
            self.home = make_home(self.root)
            self.record = os.path.join(self.root, "record.jsonl")
            self.project = make_project(self.root, self.level, self.budget)
            self.kit = os.path.join(self.root, "kit")
            os.makedirs(self.kit)
            FakeDoctor.problems = []
            env = {"CREW_HOME": self.home, "CREW_CLAUDE_BIN": make_wrapper(self.root),
                   "FAKE_CLAUDE_RECORD": self.record, "CREW_ACCOUNT": "tester"}
            p = mock.patch.dict(os.environ, env)
            p.start()
            self.addCleanup(p.stop)
            for name in ("CLAUDE_CONFIG_DIR", "FAKE_CLAUDE_SCENARIO", "FAKE_CLAUDE_CRESULT", "FAKE_CLAUDE_COST",
                         "FAKE_CLAUDE_UTIL5", "FAKE_CLAUDE_UTIL7", "FAKE_CLAUDE_TOUCH", "FAKE_CLAUDE_WAIT"):
                os.environ.pop(name, None)
            for target, value in (("crew.budget.load_doctor", lambda: FakeDoctor),
                                  ("crew.runner._kit_dir", lambda: self.kit),
                                  ("crew.runner.STOP_POLL_S", 0.05), ("crew.runner.STOP_GRACE_S", 3.0)):
                q = mock.patch(target, value)
                q.start()
                self.addCleanup(q.stop)
            self.old_cwd = os.getcwd()
            os.chdir(self.project)
            self.addCleanup(os.chdir, self.old_cwd)
            del b, runner

        def cfg(self):
            from crew import config
            return config.load(self.project)[0]

        def rows(self, t=None):
            from crew import config
            rows = config.read_ledger(self.project)
            return [r for r in rows if t is None or r.get("t") == t]

        def args(self, **kw):
            import argparse
            base = dict(task="do it", file=None, agent=None, task_id=None, approved=False, auto=False,
                        max_usd=None, quiet=False, dry_run=False, json=False)
            base.update(kw)
            return argparse.Namespace(**base)

        def call(self, fn, args):
            """Run fn(args) and return (exit code, stdout, stderr)."""
            import contextlib
            import io
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = fn(args)
            return code, out.getvalue(), err.getvalue()

        def fresh_snapshot(self, five=10.0, seven=10.0, overage=False):
            from crew import budget as b
            now = int(time.time())
            info = {"status": "rejected" if overage else "allowed", "isUsingOverage": overage,
                    "unifiedWindows": {"five_hour": {"utilization": five / 100, "resetsAt": now + 3600},
                                       "seven_day": {"utilization": seven / 100, "resetsAt": now + 86400}}}
            b.write_snapshot("tester", info, "stream")

    return CrewCase


if __name__ == "__main__":
    sys.exit(main())
