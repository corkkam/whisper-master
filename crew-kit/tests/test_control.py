from __future__ import annotations

import json
import os
import unittest
from datetime import datetime, timedelta
from unittest import mock

from crew import config, control, events
from tests import fake_claude

Base = fake_claude.case_base()


class _Tty:
    """A stdin that says whether it is a terminal."""

    def __init__(self, tty):
        self.tty = tty

    def isatty(self):
        return self.tty


class Case(Base):
    """A person at a terminal runs the commands, unless a test says otherwise."""

    def setUp(self):
        super().setUp()
        p = mock.patch("crew.control.sys.stdin", _Tty(True))
        p.start()
        self.addCleanup(p.stop)

    def no_tty(self):
        p = mock.patch("crew.control.sys.stdin", _Tty(False))
        p.start()
        self.addCleanup(p.stop)


class StopResumeTests(Case):
    def test_stop_and_resume_project(self):
        code, _, _ = self.call(control.run_stop, self.args(global_=False, reason="budget"))
        stop = os.path.join(self.project, ".crew", "STOP")
        self.assertEqual(code, 0)
        text = fake_claude.read_text(stop)
        self.assertTrue(text.startswith("stopped ") and text.strip().endswith("budget"))
        self.assertTrue(config.stop_set(self.project))
        self.assertEqual(self.rows("event")[-1]["kind"], "stop.on")
        self.assertEqual(self.rows("event")[-1]["detail"], "budget")
        self.assertEqual(fake_claude.read_events(self.home)[-1]["event"], "stop.on")
        self.call(control.run_resume, self.args(global_=False))
        self.assertFalse(os.path.exists(stop))
        self.assertEqual(self.rows("event")[-1]["kind"], "stop.off")
        self.assertEqual(fake_claude.read_events(self.home)[-1]["event"], "stop.off")

    def test_global_stop(self):
        self.call(control.run_stop, self.args(global_=True, reason=None))
        self.assertTrue(os.path.exists(os.path.join(self.home, "STOP")))
        self.assertEqual(self.rows("event")[-1]["detail"], "manual")  # an unknown word becomes "manual"
        self.assertEqual(self.call(control.run_stop, self.args(global_=True, reason="  "))[0], 0)
        self.assertEqual(self.rows("event")[-1]["detail"], "manual")  # a blank reason does not crash
        self.call(control.run_resume, self.args(global_=True))
        self.assertFalse(config.stop_set(self.project))

    def test_resume_needs_a_tty(self):
        # review kit-safety 3: the Bash tool of an agent has no TTY, so it cannot clear STOP
        self.call(control.run_stop, self.args(global_=False, reason=None))
        self.no_tty()
        code, _, err = self.call(control.run_resume, self.args(global_=False))
        self.assertEqual(code, 2)
        self.assertIn("TTY", err)
        self.assertTrue(config.stop_set(self.project))

    def test_resume_without_file_is_ok(self):
        self.assertEqual(self.call(control.run_resume, self.args(global_=False))[0], 0)

    def test_outside_project(self):
        os.chdir(self.root)
        self.assertEqual(self.call(control.run_stop, self.args(global_=False, reason=None))[0], 8)
        self.assertEqual(self.call(control.run_stop, self.args(global_=True, reason=None))[0], 0)


class EmitTests(Case):
    def emit(self, **kw):
        base = dict(event="huddle.start", agent="nova", agents="pm,qa", task=None, note=None, session=None)
        base.update(kw)
        return self.call(control.run_emit, self.args(**base))

    def test_writes_crew_event(self):
        self.assertEqual(self.emit(session="s1")[0], 0)
        e = fake_claude.read_events(self.home)[-1]
        self.assertEqual((e["src"], e["event"], e["agent"], e["agents"], e["session"], e["project"]),
                         ("crew", "huddle.start", "nova", ["pm", "qa"], "s1", self.project))
        self.assertEqual(self.emit(event="huddle.round", note="round 2")[0], 0)
        self.assertEqual(fake_claude.read_events(self.home)[-1]["note"], "round 2")

    def test_rejects_bad_input(self):
        self.assertEqual(self.emit(event="run.start")[0], 2)
        self.assertEqual(self.emit(agent=None)[0], 2)
        self.assertEqual(self.emit(note="free text")[0], 2)
        self.assertEqual(self.emit(agent="ghost")[0], 2)
        self.assertEqual(self.emit(agents="pm,ghost")[0], 2)
        self.assertFalse(os.path.exists(os.path.join(self.home, "events.jsonl")))

    def test_outside_project(self):
        os.chdir(self.root)
        self.assertEqual(self.emit()[0], 8)


class StatusTests(Case):
    def test_last_event_per_agent(self):
        events.write_event(self.project, "run.start", "nova")
        events.write_event(self.project, "agent.start", "pm")
        events.write_event(self.project, "agent.stop", "pm", note="ok")
        events.write_event("/other/project", "agent.start", "qa")
        code, out, _ = self.call(control.run_status, self.args(json=True))
        d = json.loads(out)
        by = {a["id"]: a for a in d["agents"]}
        self.assertEqual((code, d["level"], d["stop"]["project"]), (0, "L3", False))
        self.assertEqual((by["nova"]["last_event"], by["pm"]["last_event"], by["pm"]["note"]),
                         ("run.start", "agent.stop", "ok"))
        self.assertIsNone(by["qa"]["last_event"])  # the other project's event does not count

    def test_project_path_may_be_a_symlink(self):
        link = os.path.join(self.root, "link")
        os.symlink(self.project, link)
        events.write_event(link, "agent.start", "pm")
        by = {a["id"]: a for a in json.loads(self.call(control.run_status, self.args(json=True))[1])["agents"]}
        self.assertEqual(by["pm"]["last_event"], "agent.start")

    def test_text_output(self):
        _, out, _ = self.call(control.run_status, self.args(json=False))
        self.assertIn("level L3, STOP: not set", out)


class MemoryTests(Case):
    def put(self, rel, body="x\n"):
        path = os.path.join(self.project, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fake_claude.write_text(path, body)

    def test_component_files_in_load_order(self):
        for rel in ("AGENTS.md", "CLAUDE.md", "api/AGENTS.md", "api/CLAUDE.md", ".claude/agents/c-api.md",
                    "api/INTERFACE.md", "api/DECISIONS.md", ".crew/STATE.md"):
            self.put(rel)
        self.put(".claude/agent-memory/c-api/MEMORY.md", "line\n" * 300)
        code, out, _ = self.call(control.run_memory, self.args(agent="c-api", json=True))
        files = json.loads(out)["files"]
        self.assertEqual([f["path"] for f in files],
                         ["AGENTS.md", "CLAUDE.md", ".claude/agents/c-api.md",
                          ".claude/agent-memory/c-api/MEMORY.md", "api/INTERFACE.md", "api/DECISIONS.md",
                          "api/CLAUDE.md"])
        mem = files[3]
        self.assertEqual((mem["lines"], mem["bytes"]), (200, 999))  # the first 200 lines only
        self.assertEqual(files[0]["bytes"], 2)

    def test_lead_has_state(self):
        self.put(".crew/STATE.md", "state\n")
        self.put(".claude/agents/nova.md")
        _, out, _ = self.call(control.run_memory, self.args(agent="nova", json=False))
        self.assertIn(".crew/STATE.md", out)
        _, out, _ = self.call(control.run_memory, self.args(agent="pm", json=False))
        self.assertNotIn("STATE.md", out)

    def test_unknown_agent(self):
        self.assertEqual(self.call(control.run_memory, self.args(agent="ghost", json=False))[0], 2)


class CheckPublicTests(Case):
    def check(self, text):
        path = os.path.join(self.root, "t.txt")
        fake_claude.write_text(path, text)
        return self.call(control.run_check_public, self.args(text_file=path))

    def test_deny_word_exits_7(self):
        code, out, _ = self.check("Our REVENUE grew.")
        self.assertEqual((code, out.strip()), (7, "revenue"))

    def test_clean_text_exits_0(self):
        self.assertEqual(self.check("Fix the hotkey bug.")[0], 0)

    def test_project_deny_words(self):
        path = os.path.join(self.project, ".crew", "crew.json")
        d = json.loads(fake_claude.read_text(path))
        d["doctor"] = {"deny_words": ["secretword"]}
        fake_claude.write_text(path, json.dumps(d))
        self.assertEqual(self.check("revenue")[0], 0)
        self.assertEqual(self.check("a SecretWord here")[0], 7)

    def test_missing_file(self):
        self.assertEqual(self.call(control.run_check_public, self.args(text_file="/nope/x"))[0], 2)


class AutonomyTests(Case):
    def set(self, level, days=None):
        return self.call(control.run_autonomy, self.args(level=level, days=days))

    def autonomy(self):
        return json.loads(fake_claude.read_text(os.path.join(self.project, ".crew", "crew.json")))["autonomy"]

    def test_l2_clears_expiry_and_logs(self):
        code, _, _ = self.set("L2")
        a = self.autonomy()
        self.assertEqual((code, a["level"], a["expires_at"], a["set_by"]), (0, "L2", None, "owner"))
        ev = self.rows("event")[-1]
        self.assertEqual((ev["kind"], ev["level_from"], ev["level_to"]), ("autonomy", "L3", "L2"))
        self.assertEqual(config.effective_level(self.cfg(), self.rows()), "L2")

    def test_l5_needs_days_up_to_seven(self):
        self.assertEqual(self.set("L5")[0], 2)
        self.assertEqual(self.set("L5", 8)[0], 2)
        self.assertEqual(self.autonomy()["level"], "L3")
        self.assertEqual(self.set("L5", 7)[0], 0)
        a = self.autonomy()
        gap = datetime.fromisoformat(a["expires_at"]) - datetime.fromisoformat(a["set_at"])
        self.assertEqual((a["level"], gap), ("L5", timedelta(days=7)))
        self.assertEqual(config.effective_level(self.cfg(), self.rows()), "L5")

    def test_l4_defaults_to_30_days(self):
        self.assertEqual(self.set("L4")[0], 0)
        a = self.autonomy()
        self.assertEqual(datetime.fromisoformat(a["expires_at"]) - datetime.fromisoformat(a["set_at"]),
                         timedelta(days=30))
        self.assertEqual(self.set("L4", 31)[0], 2)

    def test_autonomy_needs_a_tty(self):
        # review kit-safety 3: an agent cannot raise its own level
        self.no_tty()
        code, _, err = self.set("L5", 7)
        self.assertEqual(code, 2)
        self.assertIn("TTY", err)
        self.assertEqual(self.autonomy()["level"], "L3")

    def test_bad_level_and_outside_project(self):
        self.assertEqual(self.set("L9")[0], 2)
        os.chdir(self.root)
        self.assertEqual(self.set("L2")[0], 8)

    def test_keeps_other_keys_and_resets_demotions(self):
        config.append_ledger(self.project, {"t": "event", "kind": "demote", "detail": "budget"})
        self.assertEqual(config.effective_level(self.cfg(), self.rows()), "L2")
        self.set("L3")
        self.assertEqual(config.effective_level(self.cfg(), self.rows()), "L3")
        d = json.loads(fake_claude.read_text(os.path.join(self.project, ".crew", "crew.json")))
        self.assertEqual(d["lead"], "nova")
        self.assertNotIn("gates", d)  # defaults are not written back


if __name__ == "__main__":
    unittest.main()
