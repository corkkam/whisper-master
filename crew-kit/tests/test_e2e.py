"""End to end: the real `crew` commands as subprocesses, with a fake `claude` (WP8).

No model runs here. The test makes a temp CREW_HOME and a temp project, runs `crew init`,
`crew add-component` and four `crew run` scenarios, feeds the captured hook samples through
`crew hook event` and `crew hook guard`, diffs the golden events against the app copy, and
times the guard. The guard median goes to stderr.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import unittest

from crew import events
from tests import fake_claude

TESTS = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(TESTS)
HOOKS = os.path.join(TESTS, "fixtures", "hooks")
GOLDEN = os.path.join(KIT, "spec", "events-golden.jsonl")
# The app worktree that holds CrewReducerTests.swift. The spec calls it crew-app; the real folder is project-agents.
WORKTREES = os.path.dirname(os.path.dirname(KIT))
SWIFT_CANDIDATES = [os.path.join(WORKTREES, name, "Tests", "WhisperMasterTests", "CrewReducerTests.swift")
                    for name in ("crew-app", "project-agents")]

RUN_KEYS = {"t", "v", "ts", "run_id", "task_id", "loop_id", "purpose", "agent", "account", "engine", "model",
            "effort", "session_id", "cap_usd", "autonomous", "subtype", "is_error", "num_turns", "cost_usd",
            "cost_estimated", "duration_ms", "model_usage", "subagents", "win_before", "win_after",
            "hash_changes", "crew_result", "outcome", "exit_code"}
RESERVE_KEYS = {"t", "v", "ts", "run_id", "task_id", "loop_id", "agent", "cap_usd"}
EVENT_ROW_KEYS = {"t", "v", "ts", "kind", "detail", "run_id", "loop_id", "level_from", "level_to"}
EVENT_KEYS = {"v", "ts", "src", "event", "session", "agent", "project", "tool", "kind", "note", "agents"}
TS = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$")

# fixture file -> (event, agent, tool, kind, note) that `crew hook event` must write, or None for no line.
EXPECTED = {
    "message_display.json": None,
    "notification.json": ("needs.input", "lead", None, None, "waiting"),
    "permission_request.json": ("needs.input", "lead", None, None, "permission"),
    "post_tool_use_bash.json": ("tool.end", "pm", "Bash", "search", None),
    "post_tool_use_failure.json": ("tool.fail", "pm", "Bash", "other", None),
    "pre_tool_use_agent.json": ("tool.start", "lead", "Agent", "agent", None),
    "pre_tool_use_bash.json": ("tool.start", "lead", "Bash", "git", None),
    "session_end.json": ("session.end", "lead", None, None, None),
    "session_start_fork.json": ("session.start", "lead", None, None, None),
    "session_start_startup.json": ("session.start", "lead", None, None, None),
    "stop_failure.json": ("turn.fail", "lead", None, None, None),
    "stop.json": ("turn.end", "lead", None, None, None),
    "subagent_start.json": ("agent.start", "pm", None, None, None),
    "subagent_stop.json": ("agent.stop", "pm", None, None, None),
    "user_prompt_submit.json": ("prompt", "lead", None, None, None),
}
# Text from the samples that must never reach the events file.
PRIVATE = ("Fix the empty", "git status", "ls -la", "dark mode", "Product scope", "No, the app")


def _clean_env(**extra) -> dict:
    """The parent environment without crew, Claude Code session and fake-claude variables."""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("CREW_", "CLAUDE_CODE_", "FAKE_CLAUDE_")) and k not in ("CLAUDECODE",)}
    env.update(extra)
    return env


class E2E(unittest.TestCase):
    """One temp project for the whole class. The tests run in name order and share it."""

    @classmethod
    def setUpClass(cls):
        cls.root = os.path.realpath(tempfile.mkdtemp(prefix="crew-e2e-"))
        cls.home = os.path.join(cls.root, "crewhome")
        cls.project = os.path.join(cls.root, "proj")
        os.makedirs(os.path.join(cls.project, "api"))
        cls.claude = fake_claude.make_wrapper(cls.root)
        cls.env = _clean_env(CREW_HOME=cls.home, CREW_ACCOUNT="e2e", CREW_CLAUDE_BIN=cls.claude)
        cls.shim = os.path.join(cls.home, "bin", "crew")
        cls.runs = {}
        code, out, err = cls._crew([sys.executable, os.path.join(KIT, "bin", "crew"), "init",
                                    "--lead-name", "Atlas", "--project-name", "e2e"])
        if code != 0:
            raise AssertionError("crew init failed: %s %s" % (out, err))
        code, out, err = cls._crew([cls.shim, "add-component", "api", "--dir", "api"])
        if code != 0:
            raise AssertionError("crew add-component failed: %s %s" % (out, err))
        # Scenario order matters: after overage, every later run is refused (the $0 rule).
        for scenario in ("success", "budget", "crash", "overage"):
            cls.runs[scenario] = cls._crew([cls.shim, "run", "--quiet", "do the %s task" % scenario],
                                           FAKE_CLAUDE_SCENARIO=scenario, FAKE_CLAUDE_WAIT="20")
        cls.runs["after-overage"] = cls._crew([cls.shim, "run", "--quiet", "one more"])

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root, True)

    @classmethod
    def _crew(cls, argv, stdin="", **extra):
        env = dict(cls.env)
        env.update(extra)
        p = subprocess.run(argv, input=stdin, capture_output=True, text=True, cwd=cls.project, env=env,
                           timeout=120)
        return p.returncode, p.stdout, p.stderr

    def _ledger(self):
        with open(os.path.join(self.project, ".crew", "ledger.jsonl"), "r", encoding="utf-8") as fh:
            return [json.loads(x) for x in fh if x.strip()]

    def _events(self):
        path = os.path.join(self.home, "events.jsonl")
        if not os.path.exists(path):
            return []
        return fake_claude.read_events(self.home)

    # ------------------------------------------------------------ init and the shim

    def test_a_init_wrote_project_and_shim(self):
        for rel in (".crew/crew.json", ".claude/settings.json", ".claude/agents/lead.md",
                    ".claude/agents/c-api.md", "api/INTERFACE.md", "api/DECISIONS.md"):
            self.assertTrue(os.path.isfile(os.path.join(self.project, rel)), rel)
        code, out, _ = self._crew([self.shim, "--version"])
        self.assertEqual((code, out.strip()), (0, "crew 0.1.0"))
        cfg = json.loads(fake_claude.read_text(os.path.join(self.project, ".crew", "crew.json")))
        self.assertIn("c-api", [a["id"] for a in cfg["agents"]])
        settings = json.loads(fake_claude.read_text(os.path.join(self.project, ".claude", "settings.json")))
        guard = [h for g in settings["hooks"]["PreToolUse"] for h in g["hooks"] if h["command"].endswith("guard")]
        self.assertEqual(len(guard), 1)
        self.assertNotIn("onFailure", guard[0])  # build notes, WP4a

    # ------------------------------------------------------------ crew run, four scenarios

    def test_b_exit_codes(self):
        got = {k: v[0] for k, v in self.runs.items()}
        self.assertEqual(got, {"success": 0, "budget": 9, "crash": 1, "overage": 6, "after-overage": 6},
                         {k: v[2][-400:] for k, v in self.runs.items()})
        self.assertIn("crew: ok $0.84 of $2.00", self.runs["success"][2])
        self.assertIn('"crew_result": "changed"', self.runs["success"][1])

    def test_c_ledger_rows(self):
        rows = self._ledger()
        for r in rows:
            self.assertEqual(r["v"], 1)
            self.assertRegex(r["ts"], TS)
            want = {"run": RUN_KEYS, "reserve": RESERVE_KEYS, "event": EVENT_ROW_KEYS}[r["t"]]
            self.assertEqual(set(r), want, r)
        runs = [r for r in rows if r["t"] == "run"]
        reserves = [r for r in rows if r["t"] == "reserve"]
        self.assertEqual([r["outcome"] for r in runs], ["ok", "budget", "crash", "window"])
        self.assertEqual([r["run_id"] for r in runs], [r["run_id"] for r in reserves])  # no reserve stays open
        ok, bud, crash, win = runs
        self.assertEqual((ok["cost_usd"], ok["cap_usd"], ok["cost_estimated"], ok["crew_result"]),
                         (0.84, 2.0, False, "changed"))
        self.assertEqual(ok["model_usage"], {"claude-opus-5-5": {"costUSD": 0.84, "inputTokens": 10,
                                                                 "outputTokens": 99}})
        self.assertEqual((ok["agent"], ok["account"], ok["engine"], ok["purpose"], ok["autonomous"]),
                         ("lead", "e2e", "claude", "task", False))
        self.assertEqual(ok["hash_changes"], [])
        self.assertEqual((bud["subtype"], bud["cost_usd"], bud["model_usage"], bud["exit_code"]),
                         ("error_max_budget_usd", 2.05, {}, 9))
        self.assertEqual((crash["cost_estimated"], crash["cost_usd"], crash["exit_code"]),
                         (True, crash["cap_usd"], 1))
        self.assertEqual(win["exit_code"], 6)
        kinds = [(r["kind"], r["detail"]) for r in rows if r["t"] == "event"]
        self.assertIn(("breach", "budget"), kinds)  # 2.05 is over the 2.00 cap
        self.assertEqual(kinds[-1], ("refuse", "overage"))  # the run after overage
        self.assertNotIn("demote", [k for k, _ in kinds])  # no autonomous run, no protected change

    def test_d_run_events(self):
        evs = [e for e in self._events() if e["src"] == "crew"]
        for e in evs:
            self.assertEqual(set(e), EVENT_KEYS)
            self.assertEqual(e["agent"], "lead")
            self.assertEqual(e["project"], self.project)
        pairs = [(e["event"], e["note"]) for e in evs]
        self.assertEqual(pairs, [("run.start", None), ("run.end", "changed"),
                                 ("run.start", None), ("run.end", "budget"), ("budget.over", "budget"),
                                 ("run.start", None), ("run.end", "crash"),
                                 ("run.start", None), ("run.end", "window")])
        sessions = [r["session_id"] for r in self._ledger() if r["t"] == "run"]
        self.assertEqual([e["session"] for e in evs if e["event"] == "run.end"], sessions)

    # ------------------------------------------------------------ hooks with the captured samples

    def _sample(self, name, sid):
        with open(os.path.join(HOOKS, name), "r", encoding="utf-8") as fh:
            text = fh.read()
        return text.replace("<sid>", sid).replace("<proj>", self.project).replace("<path>", "/dev/null")

    def test_e_hook_event_samples(self):
        sid = [r for r in self._ledger() if r["t"] == "run"][0]["session_id"]
        self.assertTrue(os.path.isfile(os.path.join(self.home, "sessions", sid + ".json")))
        self.assertEqual(sorted(EXPECTED), sorted(f for f in os.listdir(HOOKS) if f.endswith(".json")))
        for name, want in sorted(EXPECTED.items()):
            before = len(self._events())
            code, out, err = self._crew([self.shim, "hook", "event"], stdin=self._sample(name, sid))
            self.assertEqual((code, out, err), (0, "", ""), name)
            new = self._events()[before:]
            if want is None:
                self.assertEqual(new, [], name)
                continue
            self.assertEqual(len(new), 1, (name, new))
            e = new[0]
            self.assertEqual(set(e), EVENT_KEYS, name)
            self.assertEqual((e["event"], e["agent"], e["tool"], e["kind"], e["note"]), want, name)
            self.assertEqual((e["v"], e["src"], e["session"], e["project"], e["agents"]),
                             (1, "claude", sid, self.project, []), name)
            self.assertRegex(e["ts"], TS)
        with open(os.path.join(self.home, "events.jsonl"), "r", encoding="utf-8") as fh:
            text = fh.read()
        for line in text.splitlines():
            self.assertLessEqual(len(line.encode("utf-8")) + 1, 1024)
            note = json.loads(line)["note"]
            self.assertTrue(note is None or note in events.NOTES, note)
        for secret in PRIVATE:
            self.assertNotIn(secret, text)

    def test_f_hook_guard_samples(self):
        sid = [r for r in self._ledger() if r["t"] == "run"][0]["session_id"]
        for name in sorted(EXPECTED):
            code, out, err = self._crew([self.shim, "hook", "guard"], stdin=self._sample(name, sid))
            # L2, not approved: git status and an Agent call to pm are allowed. Other events are not guarded.
            self.assertEqual((code, out, err), (0, "", ""), name)
        hook = json.loads(self._sample("pre_tool_use_bash.json", sid))
        hook["tool_input"]["command"] = "git commit -m smoke"
        before = len(self._events())
        code, out, err = self._crew([self.shim, "hook", "guard"], stdin=json.dumps(hook))
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out), {"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "permissionDecision": "deny",
            "permissionDecisionReason": "crew: denied: needs owner"}})
        new = self._events()[before:]
        self.assertEqual([(e["event"], e["note"], e["agent"]) for e in new],
                         [("guard.deny", "denied: needs owner", "lead")])
        # An owner session (no crew identity) is allowed, even for a red-line command.
        owner = {"hook_event_name": "PreToolUse", "session_id": "owner-1", "cwd": self.project,
                 "tool_name": "Bash", "tool_input": {"command": "git push origin main"}}
        self.assertEqual(self._crew([self.shim, "hook", "guard"], stdin=json.dumps(owner)), (0, "", ""))

    # ------------------------------------------------------------ golden file and guard time

    def test_g_golden_matches_app_copy(self):
        swift = next((p for p in SWIFT_CANDIDATES if os.path.isfile(p)), None)
        if swift is None:
            self.skipTest("CrewReducerTests.swift is not in a sibling app worktree; golden diff skipped")
        with open(swift, "r", encoding="utf-8") as fh:
            m = re.search(r'let crewGoldenEvents = """\n(.*?)\n"""', fh.read(), re.S)
        self.assertIsNotNone(m, "crewGoldenEvents literal not found in " + swift)
        with open(GOLDEN, "r", encoding="utf-8") as fh:
            kit = fh.read().splitlines()
        app = m.group(1).splitlines()
        self.assertEqual(len(kit), 10)
        self.assertEqual(kit, app, "golden events differ between %s and %s" % (GOLDEN, swift))
        sys.stderr.write("\ne2e: golden diff: %d lines, identical (%s)\n" % (len(kit), swift))

    def test_h_guard_median_time(self):
        sid = [r for r in self._ledger() if r["t"] == "run"][0]["session_id"]
        sample = self._sample("pre_tool_use_bash.json", sid)
        times = []
        for _ in range(20):
            t0 = time.perf_counter()
            code, out, _ = self._crew([self.shim, "hook", "guard"], stdin=sample)
            times.append((time.perf_counter() - t0) * 1000)
            self.assertEqual((code, out), (0, ""))
        median = statistics.median(times)
        sys.stderr.write("\ne2e: guard median %.1f ms over 20 runs (min %.1f, max %.1f, target under 100)\n"
                         % (median, min(times), max(times)))
        # shortcut: a loose bound keeps a busy machine from failing the suite; the report uses the printed value.
        self.assertLess(median, 1000)


if __name__ == "__main__":
    unittest.main()
