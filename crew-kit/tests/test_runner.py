from __future__ import annotations

import argparse
import json
import os
import subprocess
import threading
import time
import unittest
from unittest import mock

from crew import budget, config, runner
from tests import fake_claude
from tests.fake_claude import FakeDoctor

Case = fake_claude.case_base()

RUN_KEYS = {"t", "v", "ts", "run_id", "task_id", "loop_id", "purpose", "agent", "account", "engine", "model",
            "effort", "session_id", "cap_usd", "autonomous", "subtype", "is_error", "num_turns", "cost_usd",
            "cost_estimated", "duration_ms", "model_usage", "subagents", "win_before", "win_after",
            "hash_changes", "crew_result", "outcome", "exit_code"}
EVENT_KEYS = {"t", "v", "ts", "kind", "detail", "run_id", "loop_id", "level_from", "level_to"}


def edit_cfg(case, fn):
    path = os.path.join(case.project, ".crew", "crew.json")
    with open(path) as fh:
        d = json.load(fh)
    fn(d)
    with open(path, "w") as fh:
        json.dump(d, fh)


def make_l4(case):
    edit_cfg(case, lambda d: (d["autonomy"].update(level="L4", set_at=fake_claude._now_iso(),
                                                   expires_at=fake_claude._later_iso(3)),
                              d["budget"].update(overage_guard_verified=True)))


class ArgvTests(Case):
    def expected(self, cap, mode, session, task, auto=False):
        argv = [self.claude, "-p", "--agent", "nova", "--session-id", session, "--name", "crew:nova:" + task,
                "--output-format", "stream-json", "--verbose", "--max-budget-usd", cap, "--max-turns", "100",
                "--model", "opus", "--effort", "high", "--settings", '{"autoContinueAtUsageLimit":false}',
                "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                "--disallowedTools", "CronCreate CronDelete RemoteTrigger SendMessage SendUserFile Monitor",
                "--permission-mode", mode]
        return argv + (["--permission-prompts", "none"] if auto else [])

    def setUp(self):
        super().setUp()
        self.claude = os.environ["CREW_CLAUDE_BIN"]

    def dry(self, **kw):
        code, out, _ = self.call(runner.run_run, self.args(dry_run=True, task_id="t-1", **kw))
        self.assertEqual(code, 0)
        self.assertEqual(self.rows(), [])  # a dry run writes nothing
        first = out.splitlines()[0]
        return json.loads(first), out

    def test_dry_run_l3(self):
        argv, out = self.dry()
        sid = argv[argv.index("--session-id") + 1]
        self.assertEqual(argv, self.expected("2.00", "auto", sid, "t-1"))
        self.assertIn("level=L3 cap_usd=2.00 approved=false purpose=task", out)
        self.assertNotIn("do it", json.dumps(argv))  # the task goes on stdin

    def test_dry_run_l1(self):
        edit_cfg(self, lambda d: d["autonomy"].update(level="L1"))
        argv, _ = self.dry()
        self.assertEqual(argv[argv.index("--permission-mode") + 1], "plan")
        self.assertNotIn("--permission-prompts", argv)

    def test_dry_run_auto(self):
        make_l4(self)
        self.fresh_snapshot()
        argv, _ = self.dry(auto=True)
        sid = argv[argv.index("--session-id") + 1]
        self.assertEqual(argv, self.expected("2.00", "auto", sid, "t-1", auto=True))

    def test_dry_run_without_shim(self):
        os.remove(os.path.join(self.home, "bin", "crew"))
        self.assertEqual(self.dry()[0][1], "-p")

    def test_build_argv_unit(self):
        agent = config.agent(self.cfg(), "pm")
        argv = runner.build_argv(self.cfg(), agent, 0.2, "L2", False, "sid", "t-9")
        self.assertEqual(argv[argv.index("--model") + 1], "sonnet")
        self.assertEqual(argv[argv.index("--effort") + 1], "medium")
        self.assertEqual(argv[argv.index("--max-budget-usd") + 1], "0.20")


class EnvTests(Case):
    def test_child_env_unit(self):
        env = runner.child_env({
            "CLAUDE_CODE_SUBAGENT_MODEL": "x", "CLAUDE_CODE_ENTRYPOINT": "x", "CLAUDE_CODE_SSE_PORT": "1",
            "CLAUDECODE": "1", "CLAUDE_PID": "2", "CLAUDE_EFFORT": "high", "CLAUDE_CONFIG_DIR": "/c",
            "CLAUDE_CODE_OAUTH_TOKEN": "tok", "PATH": "/bin"}, {"CREW_AGENT": "nova"})
        self.assertEqual(env, {"CLAUDE_CONFIG_DIR": "/c", "CLAUDE_CODE_OAUTH_TOKEN": "tok", "PATH": "/bin",
                               "CREW_AGENT": "nova"})

    def test_child_gets_clean_env_and_prompt_on_stdin(self):
        dirty = {"CLAUDE_CODE_SUBAGENT_MODEL": "x", "CLAUDE_CODE_ENTRYPOINT": "x", "CLAUDE_CODE_SSE_PORT": "1",
                 "CLAUDECODE": "1", "CLAUDE_PID": "2", "CLAUDE_EFFORT": "high", "CLAUDE_CONFIG_DIR": "/cfg",
                 "CLAUDE_CODE_OAUTH_TOKEN": "secret-value"}
        with mock.patch.dict(os.environ, dirty):
            code, _, _ = self.call(runner.run_run, self.args(task="fix the bug", task_id="t-7"))
        self.assertEqual(code, 0)
        rec = fake_claude.read_record(self.record)[0]
        env = rec["env"]
        for gone in ("CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDECODE",
                     "CLAUDE_PID", "CLAUDE_EFFORT"):
            self.assertNotIn(gone, env)
        self.assertEqual(env["CLAUDE_CONFIG_DIR"], "/cfg")
        self.assertIn("CLAUDE_CODE_OAUTH_TOKEN", env)
        self.assertEqual((env["CREW_AGENT"], env["CREW_TASK_ID"], env["CREW_PROJECT"], env["CREW_AUTONOMOUS"]),
                         ("nova", "t-7", self.project, "0"))
        self.assertTrue(env["CREW_RUN_ID"].startswith("r-"))
        self.assertTrue(rec["stdin"].startswith("[crew] task_id=t-7 run_id=%s level=L3" % env["CREW_RUN_ID"]))
        self.assertTrue(rec["stdin"].endswith("fix the bug"))
        self.assertNotIn("fix the bug", rec["argv"])
        sid = rec["argv"][rec["argv"].index("--session-id") + 1]
        self.assertEqual(config.read_session(sid)["run_id"], env["CREW_RUN_ID"])


class ScenarioTests(Case):
    def run_one(self, scenario, **kw):
        os.environ["FAKE_CLAUDE_SCENARIO"] = scenario
        return self.call(runner.run_run, self.args(task_id="t-1", **kw))

    def test_success_row(self):
        code, out, err = self.run_one("success", json=True)
        self.assertEqual(code, 0)
        row = self.rows("run")[0]
        self.assertEqual(set(row), RUN_KEYS)
        self.assertEqual((row["outcome"], row["subtype"], row["is_error"], row["cost_usd"], row["cost_estimated"],
                          row["crew_result"], row["exit_code"], row["cap_usd"], row["autonomous"]),
                         ("ok", "success", False, 0.84, False, "changed", 0, 2.0, False))
        self.assertEqual(row["model_usage"], {"claude-opus-5-5": {"costUSD": 0.84, "inputTokens": 10,
                                                                  "outputTokens": 99}})
        self.assertEqual(row["win_after"], {"five_hour": 2.0, "seven_day": 12.0})
        self.assertIsNone(row["win_before"])
        self.assertEqual(json.loads(out)["run_id"], row["run_id"])
        self.assertIn("crew: ok $0.84 of $2.00, task $0.84, today $0.84 of $10.00", err)
        ends = fake_claude.read_events(self.home)
        self.assertEqual([(e["event"], e["note"]) for e in ends], [("run.start", None), ("run.end", "changed")])

    def test_text_goes_to_stdout(self):
        _, out, _ = self.run_one("success")
        self.assertIn("All done.", out)

    def test_reserve_closed_by_run_row(self):
        self.run_one("success")
        self.assertEqual(self.rows("reserve")[0]["run_id"], self.rows("run")[0]["run_id"])
        self.assertAlmostEqual(config.spent(self.rows(), task_id="t-1"), 0.84)

    def test_budget_outcome_exit_9(self):
        code, _, err = self.run_one("budget")
        row = self.rows("run")[0]
        self.assertEqual((code, row["outcome"], row["subtype"], row["model_usage"], row["cost_usd"]),
                         (9, "budget", "error_max_budget_usd", {}, 2.05))
        # 2.05 passes the cap of 2.00: a breach row, but no demote (not autonomous)
        kinds = [(r["kind"], r["detail"]) for r in self.rows("event")]
        self.assertEqual(kinds, [("breach", "budget")])
        self.assertEqual(set(self.rows("event")[0]), EVENT_KEYS)

    def test_crash_is_estimated_at_cap(self):
        code, _, _ = self.run_one("crash")
        row = self.rows("run")[0]
        self.assertEqual((code, row["outcome"], row["cost_usd"], row["cost_estimated"], row["cap_usd"],
                          row["exit_code"], row["subtype"]), (1, "crash", 2.0, True, 2.0, 1, None))
        self.assertEqual(set(row), RUN_KEYS)

    def test_rate_limit_event_writes_snapshot(self):
        os.environ["FAKE_CLAUDE_UTIL5"] = "0.5"
        os.environ["FAKE_CLAUDE_UTIL7"] = "0.25"
        self.run_one("rate_limit")
        s = budget.read_snapshot("tester")
        self.assertEqual((s["source"], s["status"], s["five_hour"]["used_percentage"],
                          s["seven_day"]["used_percentage"]), ("stream", "allowed", 50.0, 25.0))

    def test_overage_refuses_new_run(self):
        self.fresh_snapshot(overage=True)
        code, _, err = self.run_one("success")
        self.assertEqual(code, 6)
        self.assertIn("overage", err)
        self.assertFalse(os.path.exists(self.record))
        self.assertEqual(self.rows("run"), [])

    def test_overage_stops_running_run(self):
        os.environ["FAKE_CLAUDE_WAIT"] = "20"
        code, _, _ = self.run_one("overage")
        row = self.rows("run")[0]
        self.assertEqual((code, row["outcome"], row["cost_estimated"]), (6, "window", True))

    def stop_after_child_starts(self):
        # The child writes its record line first, so STOP never lands during the preflight.
        done = threading.Event()
        self.addCleanup(done.set)

        def watch():
            while not done.wait(0.05):
                if os.path.exists(self.record):
                    done.wait(0.3)
                    fake_claude.write_text(os.path.join(self.project, ".crew", "STOP"))
                    return
        threading.Thread(target=watch, daemon=True).start()

    def test_stop_file_during_slow_run(self):
        os.environ["FAKE_CLAUDE_WAIT"] = "20"
        self.stop_after_child_starts()
        code, _, _ = self.run_one("slow")
        row = self.rows("run")[0]
        self.assertEqual((code, row["outcome"], row["exit_code"]), (130, "stopped", 130))
        note = fake_claude.read_events(self.home)[-1]
        self.assertEqual((note["event"], note["note"]), ("run.end", "stopped"))

    def test_stubborn_child_is_killed_after_two_grace_periods(self):
        os.environ["FAKE_CLAUDE_WAIT"] = "30"
        self.stop_after_child_starts()
        with mock.patch("crew.runner.STOP_GRACE_S", 0.5):
            t0 = time.time()
            code, _, _ = self.run_one("stubborn")
        self.assertLess(time.time() - t0, 10)
        row = self.rows("run")[0]
        self.assertEqual((code, row["outcome"], row["exit_code"]), (130, "stopped", 130))

    def test_failure_in_the_read_loop_still_writes_the_row(self):
        os.environ["FAKE_CLAUDE_WAIT"] = "20"
        real = subprocess.Popen

        class Boom:
            def __init__(self, f):
                self.f = f

            def __iter__(self):
                raise OSError("disk full")

        def popen(*a, **k):
            p = real(*a, **k)
            if "--agent" in a[0]:  # the claude child only, not the shim check
                p.stdout = Boom(p.stdout)
            return p
        with mock.patch("crew.runner.subprocess.Popen", popen):
            code, _, err = self.run_one("slow")
        row = self.rows("run")[0]
        self.assertEqual((code, row["outcome"], row["cost_estimated"]), (1, "error", True))
        self.assertIn("the run loop failed", err)
        self.assertEqual(self.rows("reserve")[0]["run_id"], row["run_id"])  # the reserve is closed

    def test_bad_stream_content_does_not_break_the_run(self):
        code, _, _ = self.run_one("badblock")
        self.assertEqual((code, self.rows("run")[0]["outcome"]), (0, "ok"))
        with mock.patch("crew.runner._progress", side_effect=RuntimeError("bad")):
            code, _, err = self.run_one("success")
        self.assertEqual(code, 0)
        self.assertIn("a stream line was skipped", err)

    def test_stop_set_refuses_start(self):
        fake_claude.write_text(os.path.join(self.project, ".crew", "STOP"))
        self.assertEqual(self.run_one("success")[0], 3)

    def test_hash_change_gives_breach_and_demote(self):
        os.environ["FAKE_CLAUDE_TOUCH"] = os.path.join(self.project, ".crew", "crew.json")
        code, _, err = self.run_one("success")
        row = self.rows("run")[0]
        self.assertEqual((code, row["outcome"], row["hash_changes"], row["exit_code"]),
                         (1, "ok", [".crew/crew.json"], 1))  # the row holds the exit code of crew
        self.assertIn("crew: protected files changed: .crew/crew.json", err)
        events = self.rows("event")
        self.assertEqual([(e["kind"], e["detail"]) for e in events], [("breach", "protected"), ("demote", "protected")])
        self.assertEqual((events[1]["level_from"], events[1]["level_to"]), ("L3", "L2"))
        self.assertEqual(config.effective_level(self.cfg(), self.rows()), "L2")

    def test_ledger_truncation_is_a_breach(self):
        # review kit-safety 8: cutting the ledger removes demote rows and resets the day cap
        config.append_ledger(self.project, {"t": "event", "kind": "demote", "detail": "budget"})
        real = runner.watched_hashes
        calls = []

        def cut(project, cfg):
            calls.append(1)
            if len(calls) == 2:  # after the run: an agent truncated the ledger
                with open(os.path.join(project, ".crew", "ledger.jsonl"), "w"):
                    pass
            return real(project, cfg)
        with mock.patch("crew.runner.watched_hashes", cut):
            code, _, err = self.run_one("success")
        self.assertEqual(code, 1)
        self.assertEqual(self.rows("run")[0]["hash_changes"], [".crew/ledger.jsonl"])
        self.assertIn("breach", [e["kind"] for e in self.rows("event")])

    def test_ledger_append_is_not_a_breach(self):
        mark = runner._ledger_mark(self.project)
        config.append_ledger(self.project, {"t": "event", "kind": "x", "detail": "y"})
        self.assertFalse(runner._ledger_changed(self.project, mark))

    def test_no_hash_change_means_empty_list(self):
        self.run_one("success")
        self.assertEqual(self.rows("run")[0]["hash_changes"], [])

    def test_autonomous_budget_demotes(self):
        make_l4(self)
        self.fresh_snapshot()
        code, _, _ = self.run_one("budget", auto=True)
        self.assertEqual(code, 9)
        self.assertEqual([(e["kind"], e["detail"]) for e in self.rows("event")],
                         [("breach", "budget"), ("demote", "budget")])
        self.assertEqual(config.effective_level(self.cfg(), self.rows()), "L3")
        rec = fake_claude.read_record(self.record)[0]
        self.assertEqual(rec["env"]["CREW_AUTONOMOUS"], "1")
        self.assertIn("--permission-prompts", rec["argv"])

    def test_autonomous_window_limit_stops_run(self):
        make_l4(self)
        self.fresh_snapshot(five=10)
        os.environ["FAKE_CLAUDE_UTIL5"] = "0.95"
        os.environ["FAKE_CLAUDE_WAIT"] = "20"
        code, _, _ = self.run_one("slow", auto=True)
        self.assertEqual((code, self.rows("run")[0]["outcome"]), (6, "window"))

    def test_doctor_warnings_printed_and_do_not_change_exit(self):
        FakeDoctor.problems = [{"id": "D23", "level": "warn", "path": "api", "text": "docs drift"}]
        code, _, err = self.run_one("success")
        self.assertEqual(code, 0)
        self.assertIn("crew: doctor D23 api: docs drift", err)

    def test_missing_result_line_counts_as_no_change(self):
        self.assertEqual(runner.parse_crew_result("hello"), "no_change")
        self.assertEqual(runner.parse_crew_result('x\n{"crew_result": "blocked", "pr": null}\n'), "blocked")

    def test_agent_and_errors(self):
        self.assertEqual(self.call(runner.run_run, self.args(agent="nobody"))[0], 2)
        self.assertEqual(self.call(runner.run_run, self.args(task=""))[0], 2)
        os.chdir(self.root)
        self.assertEqual(self.call(runner.run_run, self.args())[0], 8)

    def test_direct_component_run(self):
        self.call(runner.run_run, self.args(agent="c-api", task_id="t-2"))
        argv = fake_claude.read_record(self.record)[0]["argv"]
        self.assertEqual(argv[argv.index("--agent") + 1], "c-api")
        self.assertEqual(argv[argv.index("--model") + 1], "sonnet")
        self.assertEqual(self.rows("run")[0]["cap_usd"], 1.7)  # max 2.00 minus the 0.30 reserve


class ProgressTests(Case):
    def test_progress_lines_name_agents(self):
        os.environ["FAKE_CLAUDE_SCENARIO"] = "subagents"
        _, _, err = self.call(runner.run_run, self.args(task_id="t-1"))
        self.assertIn("crew: Paige (pm) started", err)
        self.assertIn("crew: Api (component) started", err)
        self.assertIn("crew: huddle start (Paige, Quinn)", err)
        self.assertIn("crew: huddle end (Paige, Quinn)", err)
        self.assertNotIn("general-purpose", err)
        self.assertNotIn("ls -la", err)
        self.assertEqual(self.rows("run")[0]["subagents"], {"pm": 1, "c-api": 1})

    def test_quiet_hides_progress(self):
        os.environ["FAKE_CLAUDE_SCENARIO"] = "subagents"
        _, _, err = self.call(runner.run_run, self.args(task_id="t-1", quiet=True))
        self.assertNotIn("started", err)
        self.assertNotIn("huddle", err)
        self.assertIn("crew: ok", err)


class HashTests(Case):
    def test_watched_files(self):
        p = self.project
        for rel, body in (("scripts/session-context.sh", "x"), (".claude/agents/a.md", "a"),
                          (".claude/skills/s/SKILL.md", "s"), (".mcp.json", "{}"), (".git/config", "c"),
                          (".git/hooks/pre-commit", "h"), (".git/objects/ab/cd", "o"), (".build/x", "b"),
                          ("node_modules/y", "n"), ("notes.txt", "n")):
            os.makedirs(os.path.dirname(os.path.join(p, rel)), exist_ok=True)
            fake_claude.write_text(os.path.join(p, rel), body)
        with open(os.path.join(p, ".claude", "settings.json"), "w") as fh:
            json.dump({"hooks": {"SessionStart": [{"hooks": [{"type": "command",
                                                              "command": "bash scripts/session-context.sh"}]}]}}, fh)
        h = runner.watched_hashes(p, self.cfg())
        for want in (".crew/crew.json", ".claude/settings.json", "scripts/session-context.sh", ".mcp.json",
                     ".claude/agents/a.md", ".claude/skills/s/SKILL.md", ".git/config", ".git/hooks/pre-commit"):
            self.assertIn(want, h)
        for no in (".git/objects/ab/cd", ".build/x", "node_modules/y", "notes.txt"):
            self.assertNotIn(no, h)
        self.assertEqual(len(next(iter(h.values()))), 64)

    def test_pycache_skipped_in_kit_only(self):
        for base in (self.kit, os.path.join(self.project, ".claude", "hooks")):
            os.makedirs(os.path.join(base, "__pycache__"), exist_ok=True)
            fake_claude.write_text(os.path.join(base, "__pycache__", "x.cpython-39.pyc"), "p")
        h = runner.watched_hashes(self.project, self.cfg())
        self.assertIn(".claude/hooks/__pycache__/x.cpython-39.pyc", h)
        self.assertFalse([k for k in h if k.endswith("x.cpython-39.pyc") and k.startswith(self.kit)])

    def test_big_file_skipped(self):
        os.makedirs(os.path.join(self.project, ".claude", "hooks"))
        with open(os.path.join(self.project, ".claude", "hooks", "big.bin"), "wb") as fh:
            fh.truncate(runner.MAX_HASH_BYTES + 1)
        self.assertNotIn(".claude/hooks/big.bin", runner.watched_hashes(self.project, self.cfg()))


class LoopTests(Case):
    level = "L4"

    def setUp(self):
        super().setUp()
        self.fresh_snapshot()

    def loop(self, **kw):
        base = dict(goal=None, backlog=False, improve=False, until=None, max_iterations=5, max_usd=None,
                    window=None, dry_run=False, quiet=True)
        base.update(kw)
        return self.call(runner.run_loop, argparse.Namespace(**base))

    def end_detail(self):
        return [r for r in self.rows("event") if r["kind"] == "loop.end"][-1]["detail"]

    def test_plateau_after_three_no_change(self):
        os.environ["FAKE_CLAUDE_CRESULT"] = "no_change"
        code, _, _ = self.loop(goal="keep going", max_iterations=10)
        runs = self.rows("run")
        self.assertEqual((code, len(runs), self.end_detail()), (0, 3, "plateau"))
        self.assertEqual({r["purpose"] for r in runs}, {"loop"})
        self.assertEqual(len({r["loop_id"] for r in runs}), 1)
        self.assertTrue(all(r["autonomous"] for r in runs))
        self.assertEqual([r["kind"] for r in self.rows("event")], ["loop.start", "loop.end"])

    def test_changed_resets_plateau_and_iterations_end(self):
        code, _, _ = self.loop(goal="g", max_iterations=2)
        self.assertEqual((code, len(self.rows("run")), self.end_detail()), (0, 2, "iterations"))

    def test_backlog_takes_first_open_line_and_marks_blocked(self):
        os.environ["FAKE_CLAUDE_CRESULT"] = "needs_approval"
        code, _, _ = self.loop(backlog=True, max_iterations=10)
        self.assertEqual((code, self.end_detail()), (0, "backlog-empty"))
        recs = fake_claude.read_record(self.record)
        self.assertTrue(recs[0]["stdin"].endswith("first task"))
        self.assertTrue(recs[1]["stdin"].endswith("second task"))
        text = fake_claude.read_text(os.path.join(self.project, ".crew", "BACKLOG.md"))
        self.assertIn("- [ ] first task (blocked)", text)
        self.assertIn("- [ ] second task (blocked)", text)
        self.assertEqual(len(self.rows("run")), 2)

    def test_backlog_empty_at_start(self):
        fake_claude.write_text(os.path.join(self.project, ".crew", "BACKLOG.md"), "# Backlog\n- [x] done\n")
        code, _, _ = self.loop(backlog=True)
        self.assertEqual((code, self.end_detail(), self.rows("run")), (0, "backlog-empty", []))

    def test_probe_runs_when_window_unknown(self):
        os.remove(budget.snapshot_path("tester"))
        self.loop(goal="g", max_iterations=1)
        self.assertEqual([r["purpose"] for r in self.rows("run")], ["probe", "loop"])

    def test_level_refuses(self):
        edit_cfg(self, lambda d: d["autonomy"].update(level="L3"))
        self.assertEqual(self.loop(goal="g")[0], 4)

    def test_improve_exit_2(self):
        code, _, err = self.loop(improve=True)
        self.assertEqual(code, 2)
        self.assertIn("crew: --improve is not in this build", err)

    def test_needs_goal_or_backlog(self):
        self.assertEqual(self.loop()[0], 2)

    def test_stop_ends_loop(self):
        fake_claude.write_text(os.path.join(self.project, ".crew", "STOP"))
        code, _, _ = self.loop(goal="g")
        self.assertEqual((code, self.end_detail()), (3, "stop"))

    def test_day_cap_ends_loop(self):
        edit_cfg(self, lambda d: d["budget"].update(per_day_usd=2.5))
        code, _, _ = self.loop(goal="g", max_iterations=5)
        self.assertEqual((code, self.end_detail()), (5, "day-cap"))

    def test_deadline_ends_loop(self):
        with mock.patch("crew.runner._deadline", return_value=1.0):
            code, _, _ = self.loop(goal="g", until="00:01")
        self.assertEqual((code, self.end_detail(), self.rows("run")), (0, "deadline", []))

    def test_protected_change_ends_loop(self):
        os.environ["FAKE_CLAUDE_TOUCH"] = os.path.join(self.project, ".crew", "crew.json")
        code, _, _ = self.loop(goal="g", max_iterations=3)
        self.assertEqual((code, self.end_detail(), len(self.rows("run"))), (1, "protected", 1))

    def test_doctor_failure_demotes_and_ends(self):
        FakeDoctor.problems = [{"id": "D01", "level": "error", "path": "x", "text": "bad"}]
        code, _, _ = self.loop(goal="g", max_iterations=3)
        self.assertEqual((code, self.end_detail()), (7, "doctor"))
        self.assertIn(("demote", "doctor"), [(r["kind"], r["detail"]) for r in self.rows("event")])

    def test_l4_needs_cap_on_iterations(self):
        self.assertEqual(self.loop(goal="g", max_iterations=11)[0], 4)

    def test_window_flag_overrides_ceiling(self):
        self.fresh_snapshot(five=92)
        code, _, _ = self.loop(goal="g", max_iterations=1)
        self.assertEqual((code, self.end_detail()), (6, "window"))
        code, _, _ = self.loop(goal="g", max_iterations=1, window=95)
        self.assertEqual((code, self.end_detail()), (0, "iterations"))

    def test_bad_iterations_and_window_exit_2(self):
        for kw in (dict(max_iterations=0), dict(max_iterations=-1), dict(window=150), dict(window=0)):
            self.assertEqual(self.loop(goal="g", **kw)[0], 2, kw)
        self.assertEqual(self.rows(), [])

    def test_empty_backlog_costs_no_probe(self):
        os.remove(budget.snapshot_path("tester"))
        fake_claude.write_text(os.path.join(self.project, ".crew", "BACKLOG.md"), "# Backlog\n")
        code, _, _ = self.loop(backlog=True)
        self.assertEqual((code, self.end_detail(), self.rows("run"), os.path.exists(self.record)),
                         (0, "backlog-empty", [], False))

    def test_dry_run_loop_writes_nothing(self):
        code, out, _ = self.loop(goal="g", dry_run=True)
        self.assertEqual(code, 0)
        self.assertIn("--permission-prompts", json.loads(out.splitlines()[0]))
        self.assertEqual(self.rows(), [])


if __name__ == "__main__":
    unittest.main()
