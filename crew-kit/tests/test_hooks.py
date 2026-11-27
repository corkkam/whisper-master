"""crew hook event and crew hook session-start (spec sections 12.2 and 14.3)."""
from __future__ import annotations

import io
import json
import os
import sys
import unittest
from unittest import mock

from crew import config, hooks
from tests.test_guard import GuardCase, sample

SECRET = "zebra-secret-41"


class MapEventTests(GuardCase):
    def mapped(self, name, agent="lead"):
        return [(e["event"], e["tool"], e["kind"], e["note"]) for e in hooks.map_event(sample(name), agent, self.proj)]

    def test_measured_samples(self):
        self.assertEqual(self.mapped("session_start_startup"), [("session.start", None, None, None)])
        self.assertEqual(self.mapped("pre_tool_use_agent"), [("tool.start", "Agent", "agent", None)])
        self.assertEqual(self.mapped("subagent_start", "pm"), [("agent.start", None, None, None)])
        self.assertEqual(self.mapped("post_tool_use_bash", "pm"), [("tool.end", "Bash", "search", None)])
        self.assertEqual(self.mapped("subagent_stop", "pm"), [("agent.stop", None, None, None)])
        self.assertEqual(self.mapped("message_display"), [])
        self.assertEqual(self.mapped("stop"), [("turn.end", None, None, None)])
        self.assertEqual(self.mapped("session_end"), [("session.end", None, None, None)])
        self.assertEqual(self.mapped("session_start_fork"), [("session.start", None, None, None)])
        self.assertEqual(self.mapped("pre_tool_use_bash"), [("tool.start", "Bash", "git", None)])

    def test_synthetic_samples(self):
        self.assertEqual(self.mapped("user_prompt_submit"), [("prompt", None, None, None)])
        self.assertEqual(self.mapped("post_tool_use_failure", "pm"), [("tool.fail", "Bash", "other", None)])
        self.assertEqual(self.mapped("permission_request"), [("needs.input", None, None, "permission")])
        self.assertEqual(self.mapped("notification"), [("needs.input", None, None, "waiting")])
        self.assertEqual(self.mapped("stop_failure"), [("turn.fail", None, None, None)])

    def test_clear_and_compact_add_a_line(self):
        for src in ("clear", "compact"):
            h = dict(sample("session_start_startup"), source=src)
            out = hooks.map_event(h, "lead", self.proj)
            self.assertEqual([(e["event"], e["note"]) for e in out], [("session.start", None), ("context.clear", src)])

    def test_agent_message_prompt_is_skipped(self):
        h = dict(sample("user_prompt_submit"), prompt='<agent-message from="a1">[Subagent hand-back]')
        self.assertEqual(hooks.map_event(h, "lead", self.proj), [])


class _HookBase(GuardCase):
    def feed(self, func, hook):
        out = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(hook))), mock.patch.object(sys, "stdout", out):
            self.assertEqual(func(None), 0)
        return out.getvalue()

    def real(self, name, sid="s1"):
        h = sample(name)
        h["cwd"], h["session_id"] = self.proj, sid
        return h

    def events(self):
        path = os.path.join(self.home, "events.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as fh:
            return [json.loads(line) for line in fh if line.strip()]


class HookEventTests(_HookBase):
    def test_events_are_written_without_content(self):
        hs = []
        for name in ("session_start_startup", "pre_tool_use_agent", "subagent_start", "post_tool_use_bash",
                     "subagent_stop", "stop", "session_end", "user_prompt_submit", "post_tool_use_failure",
                     "permission_request", "notification", "stop_failure"):
            hs.append(self.real(name))
        secret_path = os.path.join(self.proj, SECRET + ".swift")
        hs.append(dict(self.real("pre_tool_use_bash"), tool_input={"command": "grep %s ." % SECRET}))
        hs.append(dict(self.real("user_prompt_submit"), prompt="Please fix " + SECRET))
        hs.append(dict(self.real("pre_tool_use_bash"), tool_name="Write",
                       tool_input={"file_path": secret_path, "content": SECRET}))
        for h in hs:
            self.assertEqual(self.feed(hooks.run_hook_event, h), "")
        evs = self.events()
        self.assertEqual(len(evs), len(hs))
        self.assertEqual(evs[2]["agent"], "pm")
        self.assertEqual(evs[2]["event"], "agent.start")
        with open(os.path.join(self.home, "events.jsonl")) as fh:
            raw = fh.read()
        self.assertNotIn(SECRET, raw)
        self.assertNotIn("Product scope", raw)
        self.assertNotIn("ls -la", raw)

    def test_non_crew_and_builtin_lines_are_dropped(self):
        self.feed(hooks.run_hook_event, dict(self.real("pre_tool_use_bash"), agent_type="Explore"))
        h = self.real("pre_tool_use_bash")
        del h["agent_type"]
        self.feed(hooks.run_hook_event, h)
        self.assertEqual(self.events(), [])
        self.smap()
        self.feed(hooks.run_hook_event, dict(self.real("pre_tool_use_bash"), agent_type="general-purpose",
                                             agent_id="a9"))
        self.assertEqual(self.events(), [])
        self.feed(hooks.run_hook_event, dict(self.real("pre_tool_use_bash"), agent_type="lead"))
        self.assertEqual(len(self.events()), 1)

    def test_bad_input_never_raises(self):
        out = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO("{oops")), mock.patch.object(sys, "stdout", out):
            self.assertEqual(hooks.run_hook_event(None), 0)
            self.assertEqual(hooks.run_hook_session_start(None), 0)
        self.assertEqual(out.getvalue(), "")


class SessionStartTests(_HookBase):
    def start(self, source="startup", sid="s1"):
        out = self.feed(hooks.run_hook_session_start, dict(self.real("session_start_startup", sid), source=source))
        return json.loads(out) if out else None

    def prompt(self, text="next step", sid="s1", **kw):
        h = dict(self.real("user_prompt_submit", sid), prompt=text, **kw)
        out = self.feed(hooks.run_hook_session_start, h)
        return json.loads(out)["hookSpecificOutput"]["additionalContext"] if out else None

    def test_session_start_writes_map_and_context(self):
        with open(os.path.join(self.proj, ".crew", "STATE.md"), "w") as fh:
            fh.write("# State\n" + "x" * 5000)
        data = self.start()
        self.assertEqual(data["hookSpecificOutput"]["hookEventName"], "SessionStart")
        text = data["hookSpecificOutput"]["additionalContext"]
        self.assertTrue(text.startswith("Crew: you are lead (lead, Atlas) in project dogfood. Autonomy L3. "
                                        "Budget today $0.00 of $10.00. STOP: not set.\n.crew/STATE.md:\n# State"))
        self.assertLessEqual(len(text.encode("utf-8")), 2048)
        smap = config.read_session("s1")
        self.assertEqual((smap["agent"], smap["project"], smap["turns"], smap["approved"]),
                         ("lead", self.proj, 0, False))

    def test_session_start_keeps_existing_map(self):
        self.smap(run_id="r-1", approved=True, turns=3)
        self.start()
        self.assertEqual(config.read_session("s1")["run_id"], "r-1")
        self.assertEqual(config.read_session("s1")["turns"], 3)

    def test_clear_resets_turns(self):
        self.smap(turns=5)
        self.start(source="clear")
        self.assertEqual(config.read_session("s1")["turns"], 0)

    def test_reminder_turns(self):
        self.start()
        seen = {}
        for turn in range(1, 14):
            seen[turn] = self.prompt()
        self.assertIsNotNone(seen[8])
        self.assertIn("this session has had 8 prompts", seen[8])
        self.assertIsNone(seen[9])
        self.assertIsNone(seen[7])
        self.assertIsNotNone(seen[12])
        self.assertIsNone(seen[13])
        self.assertEqual(config.read_session("s1")["turns"], 13)

    def test_agent_message_and_subagent_prompts_do_not_count(self):
        self.start()
        self.prompt('<agent-message from="a1">done')
        self.prompt("x", agent_id="a1")
        self.assertEqual(config.read_session("s1")["turns"], 0)

    def test_subagent_start_texts(self):
        h = dict(self.real("subagent_start"), agent_type="c-input", agent_id="a2")
        text = json.loads(self.feed(hooks.run_hook_session_start, h))["hookSpecificOutput"]
        self.assertEqual(text["hookEventName"], "SubagentStart")
        self.assertIn("Write only inside: whisper-master/Sources/WhisperMaster/Input/", text["additionalContext"])
        self.assertIn("whisper-master/Sources/WhisperMaster/Input/INTERFACE.md", text["additionalContext"])
        text = json.loads(self.feed(hooks.run_hook_session_start, self.real("subagent_start")))
        self.assertIn(".claude/agent-memory/pm/", text["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(self.feed(hooks.run_hook_session_start,
                                   dict(self.real("subagent_start"), agent_type="Explore")), "")

    def test_old_sessions_are_pruned(self):
        self.smap(sid="old")
        old = config.session_file("old")
        os.utime(old, (1, 1))
        self.start()
        self.assertFalse(os.path.exists(old))
        self.assertTrue(os.path.exists(config.session_file("s1")))

    def test_non_crew_session_prints_nothing(self):
        h = self.real("session_start_startup")
        del h["agent_type"]
        self.assertEqual(self.feed(hooks.run_hook_session_start, h), "")
        self.assertIsNone(config.read_session("s1"))


if __name__ == "__main__":
    unittest.main()
