"""The PreToolUse guard of spec section 14.3. Every test uses CREW_HOME and a temp project."""
from __future__ import annotations

import io
import json
import os
import shutil
import statistics
import sys
import tempfile
import time
import unittest
from unittest import mock

from crew import config, guard

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "hooks")
CREW_ENV = ("CREW_AGENT", "CREW_PROJECT", "CREW_TASK_ID", "CREW_AUTONOMOUS", "CREW_RUN_ID")

# Dogfood-like crew (spec section 17.2), small.
CREW = {
    "version": 1,
    "project": {"name": "dogfood", "public_paths": ["whisper-master/"]},
    "lead": "lead",
    "agents": [
        {"id": "lead", "role": "lead", "name": "Atlas"},
        {"id": "pm", "role": "pm", "name": "Maya", "consult_on": ["user-facing"]},
        {"id": "qa", "role": "qa", "name": "Quinn", "paths": ["whisper-master/Tests/"]},
        {"id": "c-input", "role": "component", "name": "Tapper",
         "component_dir": "whisper-master/Sources/WhisperMaster/Input",
         "paths": ["whisper-master/Sources/WhisperMaster/Input/", "whisper-master/Tests/WhisperMasterTests/Hotkey*"]},
    ],
    "gates": {"rules": [
        {"tag": "security", "paths": ["whisper-master/Sources/WhisperMaster/Auth/"]},
        {"tag": "user-facing", "paths": ["whisper-master/Sources/WhisperMaster/UI/"]},
    ]},
    "autonomy": {"level": "L3", "set_at": "2026-01-01T00:00:00+00:00", "expires_at": None},
    "guard": {"protected": ["whisper-master/crew-kit/", "whisper-master/eval/", "whisper-master/.github/workflows/",
                            "whisper-master/Scripts/", "whisper-master/.claude/hooks/"]},
}

INPUT = "whisper-master/Sources/WhisperMaster/Input/Hotkey.swift"


def sample(name):
    with open(os.path.join(FIXTURES, name + ".json"), encoding="utf-8") as fh:
        return json.load(fh)


class GuardCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="crew-guard-")
        self.home = os.path.join(self.tmp, "crewhome")
        self.proj = os.path.join(self.tmp, "proj")
        os.makedirs(os.path.join(self.proj, ".crew"))
        self.env = {k: v for k, v in os.environ.items() if k not in CREW_ENV}
        self.env["CREW_HOME"] = self.home
        self._patch = mock.patch.dict(os.environ, self.env, clear=True)
        self._patch.start()
        self.write_cfg(CREW)

    def tearDown(self):
        self._patch.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_cfg(self, cfg, **over):
        data = json.loads(json.dumps(cfg))
        for key, val in over.items():
            data[key] = val
        with open(os.path.join(self.proj, ".crew", "crew.json"), "w") as fh:
            json.dump(data, fh)

    def level(self, lv):
        self.write_cfg(CREW, autonomy={"level": lv, "set_at": "2026-01-01T00:00:00+00:00", "expires_at": None})

    def smap(self, sid="s1", **kw):
        data = {"v": 1, "session": sid, "agent": "lead", "project": self.proj, "task_id": None, "run_id": None,
                "purpose": "task", "autonomous": False, "approved": False, "turns": 0,
                "created_at": "2026-11-27T00:00:00.000Z"}
        data.update(kw)
        config.write_session(sid, data)

    def hook(self, tool, tin=None, agent_type="lead", agent_id=None, cwd=None, sid="s1"):
        h = {"session_id": sid, "transcript_path": "/x", "cwd": cwd or self.proj,
             "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": tin or {}}
        if agent_type:
            h["agent_type"] = agent_type
        if agent_id:
            h["agent_id"] = agent_id
        return h

    def bash(self, cmd, **kw):
        return guard.decide(self.hook("Bash", {"command": cmd}, **kw), os.environ)

    def write(self, rel, tool="Write", **kw):
        path = rel if rel.startswith("/") else os.path.join(self.proj, rel)
        return guard.decide(self.hook(tool, {"file_path": path, "content": "x"}, **kw), os.environ)

    def route(self, task, **data):
        d = os.path.join(self.proj, ".crew", "tasks", task)
        os.makedirs(d, exist_ok=True)
        base = {"task_id": task, "gate_tags": [], "owner_gate": False, "parts": {}}
        base.update(data)
        with open(os.path.join(d, "route.json"), "w") as fh:
            json.dump(base, fh)


class IdentityTests(GuardCase):
    def test_non_crew_session_is_never_denied(self):
        for at in (None, "Explore", "cto"):
            with self.subTest(agent_type=at):
                self.assertIsNone(self.bash("git push origin main", agent_type=at))
                self.assertIsNone(guard.decide(self.hook("CronCreate", agent_type=at), os.environ))
        outside = tempfile.mkdtemp(dir=self.tmp)
        self.assertIsNone(self.bash("rm -rf x", cwd=outside))
        with open(os.path.join(self.proj, ".crew", "STOP"), "w") as fh:
            fh.write("stopped\n")
        self.assertIsNone(self.bash("ls", agent_type=None))

    def test_non_crew_session_with_broken_config_is_allowed(self):
        with open(os.path.join(self.proj, ".crew", "crew.json"), "w") as fh:
            fh.write("{broken")
        self.assertIsNone(self.bash("ls", agent_type=None))
        self.assertIsNone(self.bash("ls", agent_type="Explore"))

    def test_not_pretooluse_is_allowed(self):
        h = self.hook("Bash", {"command": "git push"})
        h["hook_event_name"] = "PostToolUse"
        self.assertIsNone(guard.decide(h, os.environ))

    def test_broken_config_denies_crew_agent(self):
        with open(os.path.join(self.proj, ".crew", "crew.json"), "w") as fh:
            fh.write('{"agents": [{"id": "lead", ')
        self.assertEqual(self.bash("ls"), "denied: config")
        self.smap()
        self.assertEqual(self.bash("ls", agent_type=None), "denied: config")

    def test_exception_after_identity_denies_config(self):
        with mock.patch.object(config, "read_ledger", side_effect=RuntimeError("boom")):
            self.assertEqual(self.bash("ls"), "denied: config")
            self.assertIsNone(self.bash("ls", agent_type=None))

    def test_exception_before_identity_allows(self):
        with mock.patch.object(config, "resolve_project", side_effect=RuntimeError("boom")):
            self.assertIsNone(self.bash("git push"))

    def test_missing_project_for_crew_agent_denies(self):
        os.remove(os.path.join(self.proj, ".crew", "crew.json"))
        os.environ["CREW_AGENT"] = "lead"
        self.assertEqual(self.bash("ls", agent_type=None), "denied: config")

    def test_stop_denies_crew_agent(self):
        with open(os.path.join(self.proj, ".crew", "STOP"), "w") as fh:
            fh.write("stopped\n")
        self.assertEqual(self.bash("ls"), "denied: stop")

    def test_global_stop_denies_crew_agent(self):
        os.makedirs(self.home, exist_ok=True)
        with open(os.path.join(self.home, "STOP"), "w") as fh:
            fh.write("stopped\n")
        self.assertEqual(self.bash("ls"), "denied: stop")


class ToolTests(GuardCase):
    def test_tool_allowlist(self):
        for tool in ("mcp__claude_ai_TickerTape__us_trade_place_write", "CronCreate", "CronDelete",
                     "RemoteTrigger", "SendMessage", "SendUserFile", "Monitor"):
            with self.subTest(tool=tool):
                self.assertEqual(guard.decide(self.hook(tool), os.environ), "denied: tool")
        self.assertIsNone(guard.decide(self.hook("Read", {"file_path": "README.md"}), os.environ))

    def test_delegation(self):
        def agent(sub, **kw):
            return guard.decide(self.hook("Agent", {"subagent_type": sub, "prompt": "p"}, **kw), os.environ)
        self.assertEqual(agent("general-purpose"), "denied: tool")
        self.assertIsNone(agent("pm"))
        self.assertEqual(agent("qa", agent_type="pm", agent_id="a1"), "denied: tool")

    def test_measured_agent_sample(self):
        h = sample("pre_tool_use_agent")
        h["cwd"], h["session_id"] = self.proj, "s9"
        self.assertIsNone(guard.decide(h, os.environ))

    def test_general_purpose_subagent_is_guarded_as_run_agent(self):
        self.smap(agent="c-input")
        kw = {"agent_type": "general-purpose", "agent_id": "a77"}
        self.assertEqual(self.bash("git push origin main", **kw), "denied: red line")
        self.assertEqual(self.write("README.md", **kw), "denied: outside paths")
        self.assertIsNone(self.write(INPUT, **kw))


class WriteTests(GuardCase):
    def test_persona_write_outside_memory_denied(self):
        kw = {"agent_type": "pm", "agent_id": "a1"}
        self.assertEqual(self.write("notes.md", **kw), "denied: outside paths")
        self.assertIsNone(self.write(".claude/agent-memory/pm/MEMORY.md", **kw))
        self.assertEqual(self.write(".claude/agent-memory/qa/MEMORY.md", **kw), "denied: outside paths")
        self.assertIsNone(self.write(".crew/tasks/t-1/pm.md", **kw))

    def test_component_write_in_worktree_inside_paths(self):
        kw = {"agent_type": "c-input", "agent_id": "a2"}
        self.assertIsNone(self.write(".claude/worktrees/wt1/" + INPUT, **kw))
        self.assertIsNone(self.write("whisper-master/.claude/worktrees/wt1/Sources/WhisperMaster/Input/A.swift", **kw))
        self.assertEqual(self.write(".claude/worktrees/wt1/whisper-master/Sources/WhisperMaster/UI/A.swift", **kw),
                         "denied: outside paths")

    def test_dogfood_protected_kit(self):
        self.assertEqual(self.write("whisper-master/crew-kit/crew/guard.py", tool="Edit"), "denied: protected path")
        self.assertEqual(self.write("whisper-master/.claude/worktrees/x/crew-kit/crew/guard.py", tool="Edit"),
                         "denied: protected path")
        self.assertEqual(self.write(".crew/crew.json"), "denied: protected path")
        self.assertIsNone(self.write("whisper-master/Sources/WhisperMaster/Input/x.swift", tool="Edit"))

    def test_tier_b_only_in_improve_worktree(self):
        self.assertEqual(self.write(".claude/agents/pm.md", tool="Edit"), "denied: protected path")
        self.assertEqual(self.write("AGENTS.md", tool="Edit"), "denied: protected path")
        self.assertIsNone(self.write(".claude/worktrees/crew-improve-a/.claude/agents/pm.md", tool="Edit"))

    def test_home_paths_denied(self):
        self.assertEqual(self.write(os.path.join(self.home, "x.json")), "denied: protected path")
        self.assertEqual(self.write(os.path.expanduser("~/.claude-shob/settings.json")), "denied: protected path")
        self.assertEqual(self.write(os.path.join(self.tmp, "elsewhere.txt")), "denied: outside paths")

    def test_route_gate(self):
        os.environ["CREW_TASK_ID"] = "t-20261127-1930-a1b2"
        self.assertEqual(self.write(INPUT), "denied: ungated")
        self.assertIsNone(self.write(".crew/tasks/t-20261127-1930-a1b2/plan.md"))
        self.route("t-20261127-1930-a1b2")
        self.assertIsNone(self.write(INPUT))
        auth = "whisper-master/Sources/WhisperMaster/Auth/Gate.swift"
        self.assertEqual(self.write(auth), "denied: ungated")
        self.route("t-20261127-1930-a1b2", gate_tags=["security"])
        self.assertIsNone(self.write(auth))

    def test_owner_gate(self):
        self.smap(task_id="t-1")
        self.route("t-1", gate_tags=["security"], owner_gate=True)
        self.assertEqual(self.write(INPUT), "denied: needs owner")
        self.assertEqual(self.bash('git commit -m "x"'), "denied: needs owner")
        self.assertIsNone(self.write(".crew/tasks/t-1/plan.md"))
        self.smap(task_id="t-1", approved=True)
        self.assertIsNone(self.write(INPUT))
        self.assertIsNone(self.bash('git commit -m "x"'))


class LevelTests(GuardCase):
    def test_l0_only_read_tools(self):
        self.level("L0")
        self.assertIsNone(guard.decide(self.hook("Grep", {"pattern": "x"}), os.environ))
        self.assertEqual(self.bash("ls"), "denied: level")
        self.assertEqual(guard.decide(self.hook("TodoWrite"), os.environ), "denied: level")

    def test_l1(self):
        self.level("L1")
        self.assertIsNone(self.bash("crew route --type qa --json"))
        self.assertIsNone(self.bash('"$HOME"/.crew/bin/crew status'))
        self.assertIsNone(self.bash("git status"))
        self.assertIsNone(self.bash("grep -r x ."))
        self.assertEqual(self.bash("make"), "denied: level")
        self.assertEqual(self.write(INPUT), "denied: level")
        self.assertEqual(self.bash("git status && make"), "denied: level")
        self.assertEqual(self.bash("ls && echo x > f"), "denied: level")
        self.assertEqual(self.bash("crew status; make"), "denied: level")
        self.assertEqual(self.bash("rm -r app; swift test"), "denied: level")
        self.assertIsNone(self.write(".crew/tasks/t-1/plan.md"))

    def test_l2_needs_owner_until_approved(self):
        self.level("L2")
        self.smap()
        self.assertEqual(self.write(INPUT), "denied: needs owner")
        self.assertEqual(self.bash("git push origin feature/x"), "denied: needs owner")
        self.assertIsNone(self.bash("swift test"))
        self.smap(approved=True)
        self.assertIsNone(self.write(INPUT))

    def test_demotion_lowers_level(self):
        config.append_ledger(self.proj, {"t": "event", "kind": "demote", "detail": "tool"})
        config.append_ledger(self.proj, {"t": "event", "kind": "demote", "detail": "tool"})
        self.assertEqual(self.bash("make"), "denied: level")  # L3 - 2 = L1

    def test_day_cap(self):
        config.append_ledger(self.proj, {"t": "run", "run_id": "r1", "cost_usd": 10.0})
        self.assertEqual(self.bash("ls"), "denied: budget")
        self.assertIsNone(guard.decide(self.hook("Read", {"file_path": "a.txt"}), os.environ))

    def test_null_day_cap_is_no_cap(self):
        self.write_cfg(CREW, budget={"per_day_usd": None})
        config.append_ledger(self.proj, {"t": "run", "run_id": "r1", "cost_usd": 99.0})
        self.assertIsNone(self.bash("ls"))


class BashTests(GuardCase):
    def test_red_line(self):
        self.assertEqual(self.bash("git push origin main"), "denied: red line")
        self.assertIsNone(self.bash("git push -u origin feature/x"))
        self.assertEqual(self.bash("crew autonomy L5 --days 7"), "denied: red line")
        self.assertEqual(self.bash("crew resume"), "denied: red line")
        self.assertEqual(self.bash("crew stop --clear"), "denied: red line")

    def test_extra_deny_bash(self):
        self.write_cfg(CREW, guard={"protected": [], "deny_bash": [r"\bterraform\b"]})
        self.assertEqual(self.bash("terraform apply"), "denied: red line")

    def test_protected_strings(self):
        self.assertEqual(self.bash("python3 -c \"open('.crew/crew.json','w')\""), "denied: protected path")
        self.assertIsNone(self.bash("python3 -m unittest discover -s crew-kit/tests"))
        self.assertEqual(self.bash("echo x > .claude/settings.json"), "denied: protected path")
        self.assertEqual(self.bash("cp a %s/.claude/agents/pm.md" % self.proj), "denied: protected path")
        self.assertEqual(self.bash('sed -i "" s/a/b/ "$HOME"/.crew/kit/x'), "denied: protected path")
        self.assertIsNone(self.bash("cat .crew/crew.json"))
        for cmd in ("echo x > .crew/crew.json; make", "echo x > .crew/crew.json && swift test",
                    ": > .crew/ledger.jsonl; make", "cp evil .claude/settings.json; make",
                    "swift test > .crew/crew.json", "cd .crew && echo x > crew.json"):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.bash(cmd), "denied: protected path")
        self.level("L2")
        self.assertEqual(self.bash("echo x > .crew/crew.json; make"), "denied: protected path")

    def test_shim_path_is_not_protected_text(self):
        self.assertIsNone(self.bash('"$HOME"/.crew/bin/crew status 2>&1'))
        self.assertIsNone(self.bash("~/.crew/bin/crew status > /dev/null"))
        self.assertEqual(self.bash('"$HOME"/.crew/bin/crew status > .crew/crew.json'), "denied: protected path")

    def test_background_mode_is_red_line(self):
        h = self.hook("Bash", {"command": "make", "run_in_background": True})
        self.assertEqual(guard.decide(h, os.environ), "denied: red line")

    def test_public_text(self):
        self.assertEqual(self.bash('git commit -m "add revenue chart"'), "denied: public text")
        self.assertEqual(self.bash("git checkout -b feature/go-to-market"), "denied: public text")
        self.assertIsNone(self.bash('git commit -m "fix hotkey"'))
        self.write_cfg(CREW, project={"name": "dogfood", "public_paths": []})
        self.assertIsNone(self.bash('git commit -m "add revenue chart"'))

    def test_private_data(self):
        def read(path, tool="Read", key="file_path"):
            return guard.decide(self.hook(tool, {key: path}), os.environ)
        self.assertEqual(read("Tests/Fixtures/audio/paragraph-1.m4a"), "denied: private data")
        self.assertEqual(read("~/Library/Application Support/WhisperMaster/x"), "denied: private data")
        self.assertEqual(read("**/*.wav", tool="Glob", key="pattern"), "denied: private data")
        self.assertEqual(read("Tests/WhisperMasterTests/Fixtures/audio", tool="LS", key="path"),
                         "denied: private data")
        self.assertEqual(self.bash('ls "$HOME/Library/Application Support/WhisperMaster"'), "denied: private data")
        self.assertEqual(self.bash("cat ~/Library/Containers/app.WhisperMaster.x/Data/a"), "denied: private data")
        self.assertEqual(self.bash('cat ~/Library/"Application Support"/WhisperMaster/db'), "denied: private data")
        self.assertEqual(self.bash("cat ~/Library/Application*/WhisperMaster/db"), "denied: private data")
        self.assertIsNone(self.bash("ls ~/Library/Developer/Xcode/DerivedData/WhisperMaster-abc"))
        self.assertIsNone(self.bash("swift test --filter AudioReplayTests"))
        self.assertIsNone(read("Sources/Audio/Capture.swift"))


class ReviewSafetyTests(GuardCase):
    """The kit-safety findings of the review (research/agent-harness/review-findings.md)."""

    def test_symlink_does_not_lead_a_write_into_protected_files(self):
        # finding 4: Write proj/c/crew.json with c -> .crew
        os.symlink(".crew", os.path.join(self.proj, "c"))
        self.assertEqual(self.write("c/crew.json"), "denied: protected path")
        os.makedirs(self.home, exist_ok=True)
        os.symlink(self.home, os.path.join(self.proj, "h"))  # a link to CREW_HOME
        self.assertEqual(self.write("h/x.json"), "denied: protected path")
        cl = os.path.join(self.tmp, "elsewhere")
        os.makedirs(cl)
        os.symlink(cl, os.path.join(self.proj, "out"))
        self.assertEqual(self.write("out/x.txt"), "denied: outside paths")
        # a link from scratch to a gated file is not scratch
        self.level("L2")
        self.smap()
        os.makedirs(os.path.join(self.proj, ".crew", "tasks", "t1"))
        os.makedirs(os.path.join(self.proj, os.path.dirname(INPUT)))
        os.symlink(os.path.join(self.proj, INPUT), os.path.join(self.proj, ".crew", "tasks", "t1", "x"))
        self.assertEqual(self.write(".crew/tasks/t1/x"), "denied: needs owner")
        self.assertIsNone(self.write(".crew/tasks/t1/plan.md"))

    def test_route_json_is_protected(self):
        # finding 5: an agent must not rewrite owner_gate or the gate tags
        self.smap(task_id="t1")
        self.route("t1", owner_gate=True)
        self.assertEqual(self.write(".crew/tasks/t1/route.json"), "denied: protected path")
        self.assertEqual(self.write(".crew/tasks/t1/route.json", tool="Edit"), "denied: protected path")
        self.assertEqual(self.bash("echo '{}' > .crew/tasks/t1/route.json"), "denied: protected path")
        self.assertEqual(self.bash("cd .crew/tasks/t1 && echo '{}' > route.json"), "denied: protected path")

    def test_quotes_do_not_hide_protected_names(self):
        # finding 8
        self.assertEqual(self.bash("cd .crew && printf x > led''ger.jsonl"), "denied: protected path")
        self.assertEqual(self.bash("echo '{}' > .cr''ew/cr''ew.json"), "denied: protected path")
        self.assertEqual(self.bash('echo x > .c\\rew/crew.json'), "denied: protected path")
        self.assertEqual(self.bash("cd .claude && echo '{}' > settings.json"), "denied: protected path")

    def test_owner_gate_sees_git_global_options(self):
        # finding 9
        self.level("L2")
        self.smap()
        self.assertEqual(self.bash("git -C . commit -m x"), "denied: needs owner")
        self.assertEqual(self.bash("git -C . push origin feature/x"), "denied: needs owner")
        self.assertEqual(self.bash("GIT commit -m x"), "denied: needs owner")
        self.assertIsNone(self.bash("git -C . status"))

    def test_secret_files_and_message_hosts(self):
        # finding 11
        def tool(name, **tin):
            return guard.decide(self.hook(name, tin), os.environ)
        self.assertEqual(tool("Read", file_path="~/.ssh/id_rsa"), "denied: private data")
        self.assertEqual(tool("Read", file_path=os.path.expanduser("~/.aws/credentials")), "denied: private data")
        self.assertEqual(tool("Read", file_path="~/.claude-shob/.credentials.json"), "denied: private data")
        self.assertEqual(tool("Read", file_path="~/Library/Keychains/login.keychain-db"), "denied: private data")
        self.assertEqual(tool("Read", file_path=os.path.join(self.proj, ".env")), "denied: private data")
        self.assertEqual(tool("Grep", pattern="x", path="~/.SSH"), "denied: private data")
        self.assertEqual(self.bash("cat ~/.ssh/id_rsa"), "denied: private data")
        self.assertEqual(self.bash("cat .env"), "denied: private data")
        self.assertIsNone(tool("Read", file_path=os.path.join(self.proj, ".env.example")))
        self.assertIsNone(self.bash("grep -r process.env src"))
        self.assertIsNone(tool("Read", file_path="~/.sshrc-notes"))
        url = "https://api.telegram.org/botX/sendMessage?chat_id=1&text=hi"
        self.assertEqual(tool("WebFetch", url=url, prompt="x"), "denied: red line")
        self.assertEqual(tool("WebFetch", url="https://HOOKS.SLACK.COM/x", prompt="x"), "denied: red line")
        self.assertIsNone(tool("WebFetch", url="https://docs.anthropic.com/claude-code", prompt="x"))

    def test_budget_probe_is_not_safe(self):
        # finding 12: a probe starts a nested claude -p
        self.level("L1")
        self.assertIsNone(self.bash("crew budget --json"))
        self.assertEqual(self.bash("crew budget --probe"), "denied: level")
        self.level("L3")
        self.assertEqual(self.bash("crew budget --probe"), "denied: red line")
        self.assertEqual(self.bash("echo '{}' | crew statusline"), "denied: red line")

    def test_non_crew_session_is_still_allowed_first(self):
        self.assertIsNone(self.bash("GIT push origin dev", agent_type=None, sid="other"))
        self.assertIsNone(guard.decide(self.hook("Read", {"file_path": "~/.ssh/id_rsa"}, agent_type=None,
                                                 sid="other"), os.environ))


class RunHookTests(GuardCase):
    def run_hook(self, hook):
        out = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(hook))), mock.patch.object(sys, "stdout", out):
            code = guard.run_hook_guard(None)
        self.assertEqual(code, 0)
        return out.getvalue()

    def events(self):
        path = os.path.join(self.home, "events.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def test_deny_prints_json_and_writes_event(self):
        out = self.run_hook(self.hook("Bash", {"command": "git push origin main"}))
        data = json.loads(out)
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(data["hookSpecificOutput"]["permissionDecisionReason"], "crew: denied: red line")
        evs = self.events()
        self.assertEqual([e["event"] for e in evs], ["guard.deny"])
        self.assertEqual(evs[0]["note"], "denied: red line")
        self.assertNotIn("git push", json.dumps(evs))
        self.assertEqual([r for r in config.read_ledger(self.proj) if r.get("kind") == "demote"], [])

    def test_allow_prints_nothing(self):
        self.assertEqual(self.run_hook(self.hook("Bash", {"command": "git status"})), "")
        self.assertEqual(self.run_hook(self.hook("Bash", {"command": "git push"}, agent_type=None)), "")
        self.assertEqual(self.events(), [])

    def test_bad_stdin_exits_zero(self):
        out = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO("not json")), mock.patch.object(sys, "stdout", out):
            self.assertEqual(guard.run_hook_guard(None), 0)
        self.assertEqual(out.getvalue(), "")

    def test_autonomous_deny_appends_demote(self):
        self.smap(autonomous=True, run_id="r-1")
        self.run_hook(self.hook("CronCreate"))
        demotes = [r for r in config.read_ledger(self.proj) if r.get("kind") == "demote"]
        self.assertEqual(len(demotes), 1)
        self.assertEqual(demotes[0]["detail"], "tool")
        self.assertEqual((demotes[0]["level_from"], demotes[0]["level_to"]), ("L3", "L2"))
        self.assertIsNone(demotes[0]["loop_id"])
        # A note outside the four does not demote.
        self.run_hook(self.hook("Bash", {"command": 'git commit -m "revenue"'}))
        self.assertEqual(len([r for r in config.read_ledger(self.proj) if r.get("kind") == "demote"]), 1)

    def test_demote_carries_loop_id(self):
        self.smap(autonomous=True, run_id="r-1", loop_id="l-7")
        self.run_hook(self.hook("CronCreate"))
        demotes = [r for r in config.read_ledger(self.proj) if r.get("kind") == "demote"]
        self.assertEqual(demotes[0]["loop_id"], "l-7")

    def test_timing(self):
        h = sample("pre_tool_use_bash")
        h["cwd"], h["session_id"] = self.proj, "s1"
        times = []
        for _ in range(50):
            t0 = time.perf_counter()
            guard.decide(h, os.environ)
            times.append(time.perf_counter() - t0)
        self.assertLess(statistics.median(times), 0.030)


if __name__ == "__main__":
    unittest.main()


class HandbackTests(unittest.TestCase):
    """Found by the first real huddle: the guard denied the persona's report, so every opinion was lost."""

    def test_subagent_handback_is_an_allowed_tool(self):
        from crew import redlines
        self.assertIn("SubagentHandback", redlines.ALLOWED_TOOLS)
