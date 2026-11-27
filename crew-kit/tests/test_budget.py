from __future__ import annotations

import io
import json
import os
import threading
import time
import unittest
from unittest import mock

from crew import budget, config
from tests import fake_claude
from tests.fake_claude import FakeDoctor

Case = fake_claude.case_base()


def pre(case, agent="nova", **kw):
    kw.setdefault("purpose", "task")
    kw.setdefault("autonomous", False)
    kw.setdefault("task_id", "t-1")
    kw.setdefault("loop_id", None)
    kw.setdefault("approved", False)
    kw.setdefault("max_usd", None)
    return budget.preflight(case.project, case.cfg(), agent, **kw)


def edit_cfg(case, fn):
    path = os.path.join(case.project, ".crew", "crew.json")
    with open(path) as fh:
        d = json.load(fh)
    fn(d)
    with open(path, "w") as fh:
        json.dump(d, fh)


class PreflightTests(Case):
    def test_cap_is_two_for_opus_lead(self):
        p = pre(self)
        self.assertTrue(p.ok)
        self.assertEqual(p.cap, 2.00)
        self.assertEqual(p.level, "L3")

    def test_reserve_and_session_map_written(self):
        p = pre(self)
        res = self.rows("reserve")
        self.assertEqual(len(res), 1)
        self.assertEqual(set(res[0]), {"t", "v", "ts", "run_id", "task_id", "loop_id", "agent", "cap_usd"})
        self.assertEqual(res[0]["run_id"], p.run_id)
        sess = config.read_session(p.session_id)
        self.assertEqual(set(sess), {"v", "session", "agent", "project", "task_id", "run_id", "purpose",
                                     "autonomous", "approved", "turns", "created_at"})

    def test_dry_run_writes_nothing(self):
        p = pre(self, dry_run=True)
        self.assertTrue(p.ok)
        self.assertEqual(self.rows(), [])
        self.assertFalse(os.path.exists(os.path.join(self.home, "sessions")))

    def test_persona_cap(self):
        self.assertEqual(pre(self, agent="pm").cap, 0.20)  # 0.50 minus the 0.30 reserve

    def test_exit_3_stop(self):
        fake_claude.write_text(os.path.join(self.project, ".crew", "STOP"))
        p = pre(self)
        self.assertEqual((p.ok, p.exit_code, p.detail), (False, 3, "stop"))
        self.assertEqual(self.rows("event")[-1]["detail"], "stop")

    def test_exit_3_global_stop(self):
        fake_claude.write_text(os.path.join(self.home, "STOP"))
        self.assertEqual(pre(self).exit_code, 3)

    def test_exit_4_level(self):
        edit_cfg(self, lambda d: d["autonomy"].update(level="L0"))
        self.assertEqual(pre(self).exit_code, 4)

    def test_exit_4_autonomous_needs_l4(self):
        p = pre(self, autonomous=True)
        self.assertEqual((p.exit_code, p.detail), (4, "level"))

    def test_exit_5_task_cap(self):
        config.append_ledger(self.project, {"t": "run", "run_id": "r-x", "task_id": "t-1", "cost_usd": 2.9})
        p = pre(self)
        self.assertEqual((p.exit_code, p.detail), (5, "task-cap"))

    def test_exit_5_day_cap_and_budget_over_event(self):
        config.append_ledger(self.project, {"t": "run", "run_id": "r-x", "task_id": "other", "cost_usd": 9.5})
        p = pre(self)
        self.assertEqual((p.exit_code, p.detail), (5, "day-cap"))
        self.assertIn("budget.over", fake_claude.read_text(os.path.join(self.home, "events.jsonl")))

    def test_exit_5_loop_cap(self):
        config.append_ledger(self.project, {"t": "run", "run_id": "r-x", "task_id": "o", "loop_id": "l-1",
                                            "cost_usd": 4.8})
        p = pre(self, loop_id="l-1")
        self.assertEqual((p.exit_code, p.detail), (5, "loop-cap"))

    def test_max_usd_lowers_cap(self):
        self.assertEqual(pre(self, max_usd=1.5).cap, 0.5)

    def test_exit_6_overage(self):
        self.fresh_snapshot(overage=True)
        p = pre(self)
        self.assertEqual((p.exit_code, p.detail), (6, "overage"))

    def test_stale_overage_still_blocks_until_a_window_resets(self):
        self.fresh_snapshot(overage=True)  # five_hour resets in 1 h, seven_day in 24 h
        with mock.patch("crew.budget.time.time", return_value=time.time() + 5000):  # old, but no reset passed
            p = pre(self)
        self.assertEqual((p.exit_code, p.detail), (6, "overage"))
        self.assertIn("crew budget --probe", p.message)
        with mock.patch("crew.budget.time.time", return_value=time.time() + 100000):  # every reset passed
            self.assertTrue(pre(self).ok)

    def test_overage_without_reset_times_stays_active(self):
        budget.write_snapshot("tester", {"status": "rejected", "isUsingOverage": True}, "stream")
        self.assertEqual(pre(self).exit_code, 6)

    def test_exit_6_autonomous_unknown_window(self):
        def l4(d):
            d["autonomy"].update(level="L4", set_at=fake_claude._now_iso(), expires_at=fake_claude._later_iso(3))
            d["budget"]["overage_guard_verified"] = True
        edit_cfg(self, l4)
        p = pre(self, autonomous=True, task_id="a")
        self.assertEqual((p.exit_code, p.detail), (6, "unknown-window"))
        self.fresh_snapshot(five=10, seven=10)
        self.assertTrue(pre(self, autonomous=True, task_id="b").ok)
        self.fresh_snapshot(five=91, seven=10)
        self.assertEqual(pre(self, autonomous=True, task_id="c").detail, "window")
        # --window raises the ceiling
        self.assertTrue(pre(self, autonomous=True, task_id="d", window_pct=95).ok)
        self.fresh_snapshot(five=10, seven=80)
        self.assertEqual(pre(self, autonomous=True, task_id="e").detail, "window")

    def test_autonomous_trusts_only_a_stream_snapshot(self):
        # review kit-safety 10: an agent can pipe any numbers into crew statusline
        def l4(d):
            d["autonomy"].update(level="L4", set_at=fake_claude._now_iso(), expires_at=fake_claude._later_iso(3))
            d["budget"]["overage_guard_verified"] = True
        edit_cfg(self, l4)
        now = int(time.time())
        low = {"five_hour": {"used_percentage": 1, "resets_at": now + 3600},
               "seven_day": {"used_percentage": 1, "resets_at": now + 86400}}
        budget.write_snapshot("tester", low, "statusline")
        self.assertEqual(pre(self, autonomous=True, task_id="a").detail, "unknown-window")
        self.assertTrue(pre(self, task_id="b").ok)  # an interactive run still reads it
        # a stream reading at 99 % stays the one an autonomous run reads, after a statusline write
        self.fresh_snapshot(five=99, seven=10)
        budget.write_snapshot("tester", low, "statusline")
        self.assertEqual(pre(self, autonomous=True, task_id="c").detail, "window")
        self.fresh_snapshot(five=10, seven=10)
        budget.write_snapshot("tester", low, "statusline")
        self.assertTrue(pre(self, autonomous=True, task_id="d").ok)

    def test_future_captured_at_is_stale(self):
        # review kit-safety 10
        now = time.time()
        snap = {"captured_at": "2036-11-27T00:00:00.000Z", "five_hour": {"used_percentage": 1, "resets_at": None},
                "seven_day": {"used_percentage": 1, "resets_at": None}}
        self.assertTrue(budget.window_state(snap, 120, now)["five_hour"]["unknown"])
        snap["captured_at"] = config.utc_ts()
        self.assertFalse(budget.window_state(snap, 120, now)["five_hour"]["unknown"])

    def test_exit_6_unverified(self):
        edit_cfg(self, lambda d: (d["autonomy"].update(level="L4", set_at=fake_claude._now_iso(),
                                                       expires_at=fake_claude._later_iso(3)),
                                  d["budget"].update(overage_guard_verified=False)))
        self.fresh_snapshot()
        self.assertEqual(pre(self, autonomous=True).detail, "unverified")

    def test_exit_7_shim_missing(self):
        os.remove(os.path.join(self.home, "bin", "crew"))
        p = pre(self)
        self.assertEqual((p.exit_code, p.detail), (7, "doctor"))
        self.assertEqual(self.rows("reserve"), [])

    def test_exit_7_doctor_d11(self):
        FakeDoctor.problems = [{"id": "D11", "level": "error", "path": "x", "text": "no hooks"}]
        self.assertEqual(pre(self).exit_code, 7)
        FakeDoctor.problems = [{"id": "D17", "level": "error", "path": "x", "text": "other"}]
        self.assertTrue(pre(self).ok)

    def test_two_threads_one_day_cap(self):
        edit_cfg(self, lambda d: d["budget"].update(per_day_usd=3.0))
        cfg, results, gate = self.cfg(), [], threading.Barrier(2)

        def go(i):
            gate.wait()
            results.append(budget.preflight(self.project, cfg, "nova", purpose="task", autonomous=False,
                                            task_id="t-%d" % i, loop_id=None, approved=False, max_usd=None))
        ts = [threading.Thread(target=go, args=(i,)) for i in range(2)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        self.assertEqual(sorted(r.ok for r in results), [False, True])
        self.assertEqual(len(self.rows("reserve")), 1)
        self.assertEqual([r.exit_code for r in results if not r.ok], [5])


class SnapshotTests(Case):
    def test_stream_snapshot(self):
        info = {"status": "allowed", "isUsingOverage": False, "overageStatus": None,
                "unifiedWindows": {"five_hour": {"utilization": 0.02, "resetsAt": 1795795800},
                                   "seven_day": {"utilization": 0.12, "resetsAt": 1796263200}}}
        budget.write_snapshot("a", info, "stream")
        s = budget.read_snapshot("a")
        self.assertEqual(s["source"], "stream")
        self.assertEqual(s["five_hour"], {"used_percentage": 2.0, "resets_at": 1795795800})
        self.assertEqual(s["seven_day"]["used_percentage"], 12.0)
        self.assertEqual(set(s), {"v", "account", "captured_at", "source", "status", "is_using_overage",
                                  "overage_status", "five_hour", "seven_day"})
        self.assertFalse(os.path.exists(budget.snapshot_path("a") + ".tmp"))

    def test_statusline_snapshot_has_null_status(self):
        budget.write_snapshot("a", {"five_hour": {"used_percentage": 23, "resets_at": 5}}, "statusline")
        s = budget.read_snapshot("a")
        self.assertIsNone(s["status"])
        self.assertIsNone(s["seven_day"])
        self.assertFalse(budget.on_overage(s))

    def test_unknown_rules(self):
        now = time.time()
        self.assertTrue(all(w["unknown"] for w in budget.window_state(None, 100).values()))
        budget.write_snapshot("a", {"five_hour": {"used_percentage": 1, "resets_at": now + 100},
                                    "seven_day": {"used_percentage": 1, "resets_at": now - 5}}, "statusline")
        st = budget.window_state(budget.read_snapshot("a"), 100)
        self.assertFalse(st["five_hour"]["unknown"])
        self.assertTrue(st["seven_day"]["unknown"])  # its reset time is in the past
        self.assertTrue(budget.window_state(budget.read_snapshot("a"), 100, now + 500)["five_hour"]["unknown"])

    def test_overage_status(self):
        self.assertTrue(budget.on_overage({"status": "rejected"}))
        self.assertTrue(budget.on_overage({"status": "allowed", "is_using_overage": True}))
        self.assertFalse(budget.on_overage({"status": "allowed_warning", "is_using_overage": False}))


    def test_statusline_keeps_live_overage_of_stream_snapshot(self):
        self.fresh_snapshot(overage=True)
        budget.write_snapshot("tester", {"five_hour": {"used_percentage": 5, "resets_at": time.time() + 99}},
                              "statusline")
        s = budget.read_snapshot("tester")
        self.assertEqual((s["source"], s["is_using_overage"], s["status"]), ("statusline", True, "rejected"))
        self.assertEqual(pre(self).exit_code, 6)
        # a second statusline write keeps it too
        budget.write_snapshot("tester", {"five_hour": {"used_percentage": 6, "resets_at": time.time() + 99}},
                              "statusline")
        self.assertTrue(budget.on_overage(budget.read_snapshot("tester")))

    def test_statusline_drops_overage_after_reset(self):
        now = time.time()
        info = {"status": "rejected", "isUsingOverage": True,
                "unifiedWindows": {"five_hour": {"utilization": 0.5, "resetsAt": now - 10},
                                   "seven_day": {"utilization": 0.5, "resetsAt": now - 5}}}
        budget.write_snapshot("tester", info, "stream")
        budget.write_snapshot("tester", {"five_hour": {"used_percentage": 1, "resets_at": now + 99}}, "statusline")
        self.assertFalse(budget.on_overage(budget.read_snapshot("tester")))


class CommandTests(Case):
    def test_budget_json(self):
        self.fresh_snapshot(five=23, seven=41)
        code, out, _ = self.call(budget.run_budget, self.args(json=True, task="t-1", runs=None, probe=False))
        d = json.loads(out)
        self.assertEqual(code, 0)
        self.assertEqual(d["level"], "L3")
        self.assertAlmostEqual(d["windows"]["five_hour"]["used_pct"], 23.0)
        self.assertEqual(d["windows"]["five_hour"]["limit_pct"], 90)
        self.assertEqual(d["today"]["cap_usd"], 10.0)
        self.assertFalse(d["overage"])

    def test_budget_text_shows_windows_first(self):
        _, out, _ = self.call(budget.run_budget, self.args(json=False, task=None, runs=None, probe=False))
        lines = out.splitlines()
        self.assertTrue(lines[1].startswith("5-hour window"))
        self.assertTrue(lines[-1].startswith("today"))

    def test_budget_outside_project(self):
        os.chdir(self.root)
        self.assertEqual(self.call(budget.run_budget, self.args(json=False, task=None, runs=None, probe=False))[0], 8)

    def test_probe_writes_snapshot_and_row(self):
        self.call(budget.run_budget, self.args(json=True, task=None, runs=None, probe=True))
        s = budget.read_snapshot("tester")
        self.assertEqual(s["five_hour"]["used_percentage"], 2.0)
        row = self.rows("run")[0]
        self.assertEqual(row["purpose"], "probe")
        argv = fake_claude.read_record(self.record)[0]["argv"]
        self.assertIn("--strict-mcp-config", argv)
        self.assertEqual(argv[argv.index("--model") + 1], "haiku")

    def test_probe_skipped_on_overage_and_at_l0(self):
        self.fresh_snapshot(overage=True)
        _, _, err = self.call(budget.run_budget, self.args(json=True, task=None, runs=None, probe=True))
        self.assertIn("probe skipped", err)
        self.assertFalse(os.path.exists(self.record))
        self.assertEqual(self.rows("run"), [])
        self.fresh_snapshot()
        edit_cfg(self, lambda d: d["autonomy"].update(level="L0"))
        self.call(budget.run_budget, self.args(json=True, task=None, runs=None, probe=True))
        self.assertFalse(os.path.exists(self.record))

    def test_probe_runs_when_overage_is_over(self):
        self.fresh_snapshot(overage=True)
        with mock.patch("crew.budget.time.time", return_value=time.time() + 100000):
            self.assertTrue(budget.run_probe(self.project, self.cfg()))
        self.assertEqual([r["purpose"] for r in self.rows("run")], ["probe"])

    def test_statusline_writes_and_prints(self):
        raw = json.dumps({"rate_limits": {"five_hour": {"used_percentage": 23.4, "resets_at": 9999999999},
                                          "seven_day": {"used_percentage": 41, "resets_at": 9999999999}}})
        with mock.patch("sys.stdin", io.StringIO(raw)):
            code, out, _ = self.call(budget.run_statusline, self.args(install=False))
        self.assertEqual((code, out.strip()), (0, "crew 5h 23% 7d 41%"))
        self.assertEqual(budget.read_snapshot("tester")["source"], "statusline")

    def test_statusline_in_a_crew_run_writes_no_snapshot(self):
        # review kit-safety 10
        raw = json.dumps({"rate_limits": {"five_hour": {"used_percentage": 1, "resets_at": 9999999999}}})
        with mock.patch.dict(os.environ, {"CREW_AGENT": "nova", "CREW_RUN_ID": "r-1"}):
            with mock.patch("sys.stdin", io.StringIO(raw)):
                self.assertEqual(self.call(budget.run_statusline, self.args(install=False))[0], 0)
        self.assertIsNone(budget.read_snapshot("tester"))

    def test_statusline_next_passthrough_and_bad_input(self):
        with mock.patch.dict(os.environ, {"CREW_STATUSLINE_NEXT": "tr a-z A-Z"}):
            with mock.patch("sys.stdin", io.StringIO('{"x": "hello"}')):
                code, out, _ = self.call(budget.run_statusline, self.args(install=False))
        self.assertEqual((code, out.strip()), (0, '{"X": "HELLO"}'))
        with mock.patch("sys.stdin", io.StringIO("not json")):
            self.assertEqual(self.call(budget.run_statusline, self.args(install=False))[0], 0)

    def test_statusline_install_prints_snippet(self):
        _, out, _ = self.call(budget.run_statusline, self.args(install=True))
        self.assertIn("statusLine", json.loads(out))


if __name__ == "__main__":
    unittest.main()
