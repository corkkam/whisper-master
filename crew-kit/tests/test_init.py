"""Tests for crew init, install, add-component and add-persona (WP4a)."""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from crew import init

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INIT_DEFAULTS = dict(lead_name="Juno", project_name=None, personas="pm,qa,design,marketing,user,architect",
                     no_helper=False, no_agents_block=False, dry_run=False, force=False)
IFACE_KEYS = ("component", "owner", "interface_version", "last_verified", "verified_by")
IFACE_HEADINGS = ("Purpose", "Entry points", "Inputs and outputs", "Errors and invariants", "Architecture",
                  "Do not", "Used by")


def ns(**kw):
    return argparse.Namespace(**kw)


def tree_hashes(root):
    out = {}
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x != ".git"]
        for f in files:
            p = os.path.join(d, f)
            with open(p, "rb") as fh:
                out[os.path.relpath(p, root)] = hashlib.sha256(fh.read()).hexdigest()
    return out


class InitTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self.home = os.path.join(self.tmp, "crewhome")
        self.proj = os.path.join(self.tmp, "proj")
        os.makedirs(self.proj)
        subprocess.run(["git", "init", "-q", self.proj], check=True)
        self.env = mock.patch.dict(os.environ, {"CREW_HOME": self.home})
        self.env.start()
        self.cwd = os.getcwd()
        os.chdir(self.proj)

    def tearDown(self):
        os.chdir(self.cwd)
        self.env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def call(self, fn, **kw):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = fn(ns(**kw))
        self.out, self.err = out.getvalue(), err.getvalue()
        return code

    def init(self, **kw):
        args = dict(INIT_DEFAULTS)
        args.update(kw)
        return self.call(init.run_init, **args)

    def p(self, rel):
        return os.path.join(self.proj, rel)

    def read(self, rel):
        with open(self.p(rel), encoding="utf-8") as fh:
            return fh.read()

    def cfg(self):
        return json.loads(self.read(".crew/crew.json"))


class TestInit(InitTestCase):
    def test_init_writes_every_file_and_the_shim_runs(self):
        self.assertEqual(self.init(), 0, self.err)
        for rel in (".crew/crew.json", ".crew/.gitignore", ".crew/STATE.md", ".crew/BACKLOG.md",
                    ".claude/skills/crew-huddle/SKILL.md", ".claude/skills/crew-retro/SKILL.md",
                    ".claude/settings.json", "AGENTS.md", "CLAUDE.md", "DECISIONS.md", "ARCHITECTURE.md",
                    "memory/MEMORY.md"):
            self.assertTrue(os.path.isfile(self.p(rel)), rel)
        cfg = self.cfg()
        self.assertEqual(cfg["lead"], "lead")
        self.assertEqual(cfg["autonomy"]["level"], "L2")
        self.assertEqual(cfg["routing"], [{"when": {"type": "qa"}, "assign": "qa", "consult": ["pm"]}])
        for a in cfg["agents"]:
            self.assertTrue(os.path.isfile(self.p(".claude/agents/%s.md" % a["id"])), a["id"])
        self.assertEqual(self.read(".crew/.gitignore").split(), ["ledger.jsonl", "ledger.lock", "STOP", "tasks/",
                                                                "inbox/", "*.tmp"])
        self.assertEqual(self.read("CLAUDE.md"), "@AGENTS.md\n")
        self.assertIn("- [ ] Example:", self.read(".crew/BACKLOG.md"))
        block = re.search(r"<!-- crew:begin -->.*<!-- crew:end -->", self.read("AGENTS.md"), re.S).group(0)
        self.assertLessEqual(len(block.splitlines()), 60)
        shim = os.path.join(self.home, "bin", "crew")
        with open(shim) as fh:
            lines = fh.read().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertIn(" -I ", lines[1])
        r = subprocess.run([shim, "--version"], stdout=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(r.stdout.strip(), "crew 0.1.0")
        self.assertTrue(os.path.isfile(os.path.join(self.home, "kit", "0.1.0", "crew", "init.py")))

    def test_doctor_passes_after_init(self):
        if not os.path.isfile(os.path.join(KIT, "crew", "doctor.py")):
            self.skipTest("crew/doctor.py does not exist yet")
        self.assertEqual(self.init(), 0, self.err)
        r = subprocess.run([os.path.join(self.home, "bin", "crew"), "doctor"], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, universal_newlines=True, cwd=self.proj)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_folder_scan_gives_default_gate_rules(self):
        for d in ("Sources/App/UI", "Sources/App/UI/auth", "server/auth", "scripts", "node_modules/ui", ".hidden/ui"):
            os.makedirs(self.p(d))
        self.assertEqual(self.init(), 0, self.err)
        rules = {r["tag"]: r["paths"] for r in self.cfg()["gates"]["rules"]}
        # Sources/App is an "app" folder, so its nested UI and auth folders are skipped.
        self.assertEqual(rules, {"user-facing": ["Sources/App/"], "security": ["server/auth/"],
                                 "release": ["scripts/"]})

    def test_scan_ui_folder(self):
        for d in ("src/UI", "auth", "scripts"):
            os.makedirs(self.p(d))
        rules = {r["tag"]: r["paths"] for r in init.scan_rules(self.proj)}
        self.assertEqual(rules, {"user-facing": ["src/UI/"], "security": ["auth/"], "release": ["scripts/"]})

    def test_second_init_exits_2_and_changes_nothing(self):
        self.assertEqual(self.init(), 0, self.err)
        before = tree_hashes(self.proj)
        self.assertEqual(self.init(), 2)
        self.assertEqual(tree_hashes(self.proj), before)

    def test_force_rewrites_only_agents_skills_and_block(self):
        self.assertEqual(self.init(), 0, self.err)
        with open(self.p(".claude/agents/pm.md"), "a") as fh:
            fh.write("edited\n")
        with open(self.p(".claude/skills/crew-retro/SKILL.md"), "a") as fh:
            fh.write("edited\n")
        with open(self.p(".crew/STATE.md"), "a") as fh:
            fh.write("edited\n")
        before = tree_hashes(self.proj)
        self.assertEqual(self.init(force=True), 0, self.err)
        after = tree_hashes(self.proj)
        changed = {k for k in after if before.get(k) != after[k]} | (set(before) - set(after))
        self.assertEqual(changed, {".claude/agents/pm.md", ".claude/skills/crew-retro/SKILL.md"})
        self.assertNotIn("edited", self.read(".claude/agents/pm.md"))
        self.assertIn("edited", self.read(".crew/STATE.md"))

    def test_settings_merge_keeps_existing_and_does_not_duplicate(self):
        os.makedirs(self.p(".claude"))
        own = {"type": "command", "command": "scripts/session-context.sh"}
        with open(self.p(".claude/settings.json"), "w") as fh:
            json.dump({"model": "opus", "hooks": {"SessionStart": [{"hooks": [own]}]}}, fh)
        self.assertEqual(self.init(), 0, self.err)
        s = json.loads(self.read(".claude/settings.json"))
        self.assertEqual(s["model"], "opus")
        self.assertEqual(s["hooks"]["SessionStart"][0]["hooks"], [own])
        again = init.merge_settings(s)
        self.assertEqual(again, s)
        cmds = [h["command"] for g in s["hooks"]["PreToolUse"] for h in g["hooks"]]
        self.assertEqual(cmds.count('"$HOME"/.crew/bin/crew hook guard'), 1)
        guard = [h for g in s["hooks"]["PreToolUse"] for h in g["hooks"] if h["command"].endswith("guard")][0]
        self.assertNotIn("async", guard)
        self.assertNotEqual(guard.get("onFailure"), "block")  # build notes
        ups = [h for g in s["hooks"]["UserPromptSubmit"] for h in g["hooks"]]
        self.assertTrue(any(h["command"].endswith("session-start") and not h.get("async") for h in ups))

    def test_invalid_settings_json_writes_nothing(self):
        os.makedirs(self.p(".claude"))
        with open(self.p(".claude/settings.json"), "w") as fh:
            fh.write("{bad")
        before = tree_hashes(self.proj)
        self.assertEqual(self.init(), 2)
        self.assertEqual(tree_hashes(self.proj), before)

    def test_symlinked_agents_folder_is_refused(self):
        os.makedirs(self.p("elsewhere"))
        os.makedirs(self.p(".claude"))
        os.symlink(self.p("elsewhere"), self.p(".claude/agents"))
        self.assertEqual(self.init(), 2)
        self.assertIn("replace the .claude/agents symlink with a folder first", self.err)
        self.assertFalse(os.path.exists(self.p(".crew")))

    def test_no_agents_block_writes_pending_file(self):
        with open(self.p("AGENTS.md"), "w") as fh:
            fh.write("# Mine\n")
        self.assertEqual(self.init(no_agents_block=True), 0, self.err)
        self.assertEqual(self.read("AGENTS.md"), "# Mine\n")
        self.assertIn("<!-- crew:begin -->", self.read(".crew/agents-block.pending.md"))

    def test_existing_agents_md_gets_block_appended(self):
        with open(self.p("AGENTS.md"), "w") as fh:
            fh.write("# Mine\n")
        self.assertEqual(self.init(), 0, self.err)
        text = self.read("AGENTS.md")
        self.assertTrue(text.startswith("# Mine\n"))
        self.assertIn("<!-- crew:end -->", text)
        self.assertFalse(os.path.exists(self.p("CLAUDE.md")))  # AGENTS.md existed, so no CLAUDE.md

    def test_dry_run_writes_nothing(self):
        before = tree_hashes(self.proj)
        self.assertEqual(self.init(dry_run=True), 0, self.err)
        self.assertEqual(tree_hashes(self.proj), before)
        self.assertFalse(os.path.exists(self.home))
        self.assertIn(".claude/agents/lead.md", self.out)
        self.assertIn(".crew/crew.json", self.out)

    def test_bad_lead_name(self):
        self.assertEqual(self.init(lead_name="9lives"), 2)

    def test_lead_file_size_and_commands(self):
        self.assertEqual(self.init(), 0, self.err)
        text = self.read(".claude/agents/lead.md")
        self.assertLessEqual(len(text.encode("utf-8")), 4096)
        for s in ("crew route --task", "crew emit huddle.start --agent", "crew check-public",
                  "git -C <worktree> push -u origin feature/<slug>", "You are Juno", "maxTurns: 80"):
            self.assertIn(s, text)
        for a in self.cfg()["agents"]:
            if a["role"] not in ("lead", "component"):
                size = len(self.read(".claude/agents/%s.md" % a["id"]).encode("utf-8"))
                self.assertLessEqual(size, 2048, a["id"])
        self.assertIn("PostHog data outranks", self.read(".claude/agents/user.md"))
        self.assertNotIn("lens:", self.read(".claude/agents/pm.md"))


    def test_lead_l2_stop_needs_approved_false(self):
        self.assertEqual(self.init(), 0, self.err)
        text = self.read(".claude/agents/lead.md")
        stop = [s for s in re.split(r"(?<=\.) ", text) if "level=L2" in s]
        self.assertEqual(len(stop), 1, stop)
        self.assertIn("approved=false", stop[0])
        self.assertIn("needs_approval", stop[0])
        self.assertIn("With approved=true", text)
        self.assertIn("gh pr create --base <default> --body-file <file>", text)
        self.assertIn('"branch": "<branch or null>", "pr": <number or null>', text)
        self.assertIn("split_required", text)

    def test_lead_file_fits_with_long_names(self):
        cfg = {"project": {"name": "p" * 40}, "lead": "lead"}
        text = init.agent_file({"id": "lead", "role": "lead", "name": "A" * 24}, cfg)
        self.assertLessEqual(len(text.encode("utf-8")), 4096)

    def test_limits_exit_2_before_any_write(self):
        before = tree_hashes(self.proj)
        for attr, value in (("BLOCK_MAX_LINES", 10), ("LEAD_MAX_BYTES", 100)):
            with mock.patch.object(init, attr, value):
                self.assertEqual(self.init(), 2, attr)
            self.assertEqual(tree_hashes(self.proj), before, attr)
            self.assertFalse(os.path.exists(self.home), attr)

    def test_crew_json_is_written_last(self):
        self.assertEqual(self.init(dry_run=True), 0, self.err)
        writes = [x for x in self.out.splitlines() if x.startswith("would write .")]
        self.assertEqual(writes[-1], "would write .crew/crew.json")

    def test_helper_name_differs_from_lead_name(self):
        self.assertEqual(self.init(lead_name="Scout"), 0, self.err)
        names = [a["name"].lower() for a in self.cfg()["agents"]]
        self.assertEqual(len(names), len(set(names)), names)

    def test_force_keeps_agents_md_without_markers(self):
        self.assertEqual(self.init(no_agents_block=True), 0, self.err)
        os.remove(self.p(".crew/agents-block.pending.md"))
        with open(self.p("AGENTS.md"), "w") as fh:
            fh.write("# Mine\n")
        self.assertEqual(self.init(force=True), 0, self.err)
        self.assertEqual(self.read("AGENTS.md"), "# Mine\n")
        self.assertFalse(os.path.exists(self.p("CLAUDE.md")))
        self.assertIn("<!-- crew:begin -->", self.read(".crew/agents-block.pending.md"))


class TestAdd(InitTestCase):
    def setUp(self):
        super().setUp()
        self.assertEqual(self.init(), 0, self.err)

    def test_add_component(self):
        os.makedirs(self.p("src/input"))
        code = self.call(init.run_add_component, id="input", dir="src/input", paths=None, name=None, model=None,
                         effort=None, consult_on=None, dry_run=False)
        self.assertEqual(code, 0, self.err)
        a = [x for x in self.cfg()["agents"] if x["id"] == "c-input"][0]
        self.assertEqual(a["name"], "Input")
        self.assertEqual(a["paths"], ["src/input/"])
        self.assertEqual(list(self.cfg())[:4], ["version", "project", "lead", "agents"])
        self.assertTrue(self.read(".crew/crew.json").startswith('{\n  "version": 1'))
        iface = self.read("src/input/INTERFACE.md")
        for k in IFACE_KEYS:
            self.assertRegex(iface, r"(?m)^%s: " % k)
        heads = re.findall(r"(?m)^## (.+)$", iface)
        self.assertEqual(heads, list(IFACE_HEADINGS))
        self.assertEqual(self.read("src/input/DECISIONS.md"), "# Input decisions\n")
        self.assertIn("| c-input | component | Input |", self.read("AGENTS.md"))
        self.assertIn("name: c-input", self.read(".claude/agents/c-input.md"))
        self.assertEqual(self.call(init.run_add_component, id="input", dir="src/input", paths=None, name=None,
                                   model=None, effort=None, consult_on=None, dry_run=False), 2)

    def test_add_persona_custom(self):
        lens = "Would a new user pay for this?\\nWhich channel brings them?\\nWhat is the cheapest test?"
        code = self.call(init.run_add_persona, id="growth", role="custom", name="Gus", consult_on="launch,pricing",
                         lens=lens, model="sonnet", dry_run=False)
        self.assertEqual(code, 0, self.err)
        a = [x for x in self.cfg()["agents"] if x["id"] == "growth"][0]
        self.assertEqual(a, {"id": "growth", "role": "custom", "name": "Gus", "consult_on": ["launch", "pricing"]})
        text = self.read(".claude/agents/growth.md")
        self.assertIn("Which channel brings them?\n", text)
        self.assertIn("memory: project", text)
        self.assertLessEqual(len(text.encode("utf-8")), 2048)
        self.assertIn("| growth | custom | Gus |", self.read("AGENTS.md"))
        # duplicate id
        self.assertEqual(self.call(init.run_add_persona, id="growth", role="custom", name="Gus",
                                   consult_on="launch", lens=lens, model="sonnet", dry_run=False), 2)
        # a later --force keeps the custom lens
        self.assertEqual(self.init(force=True), 0, self.err)
        self.assertIn("Which channel brings them?", self.read(".claude/agents/growth.md"))

    def test_add_persona_needs_lens_and_valid_tags(self):
        self.assertEqual(self.call(init.run_add_persona, id="support", role="custom", name="Sam",
                                   consult_on="user-facing", lens=None, model="sonnet", dry_run=False), 2)
        self.assertEqual(self.call(init.run_add_persona, id="support", role="custom", name="Sam",
                                   consult_on="nope", lens="a\nb\nc", model="sonnet", dry_run=False), 2)
        self.assertFalse(os.path.exists(self.p(".claude/agents/support.md")))

    def test_bad_names_are_refused(self):
        for bad in ("X\ntools: Bash, Edit", "Gus|x", "Gus: x"):
            self.assertEqual(self.call(init.run_add_persona, id="support", role="custom", name=bad,
                                       consult_on="user-facing", lens="a\nb\nc", model="sonnet", dry_run=False), 2, bad)
            os.makedirs(self.p("src/input"), exist_ok=True)
            self.assertEqual(self.call(init.run_add_component, id="input", dir="src/input", paths=None, name=bad,
                                       model=None, effort=None, consult_on=None, dry_run=False), 2, bad)
        self.assertFalse(os.path.exists(self.p(".claude/agents/support.md")))
        self.assertFalse(os.path.exists(self.p(".claude/agents/c-input.md")))
        self.assertEqual(self.cfg()["agents"][-1]["id"], "scout")

    def test_add_outside_project_exits_8(self):
        os.chdir(self.tmp)
        self.assertEqual(self.call(init.run_add_persona, id="support", role="custom", name="Sam",
                                   consult_on="user-facing", lens="a\nb\nc", model="sonnet", dry_run=False), 8)


class TestTemplates(unittest.TestCase):
    def test_no_stale_draft_names(self):
        root = os.path.join(KIT, "crew", "templates")
        seen = 0
        for d, _dirs, files in os.walk(root):
            for f in files:
                with open(os.path.join(d, f), encoding="utf-8") as fh:
                    text = fh.read()
                seen += 1
                for bad in ("consult_first", ".crew/huddles", ".crew/improvements", "crew-handoff"):
                    self.assertNotIn(bad, text, "%s in %s" % (bad, f))
                if d.endswith("agents"):
                    self.assertIn("\nmemory: project\n", text, f)
        self.assertGreaterEqual(seen, 12)


class TestKitCorrectness(InitTestCase):
    def doctor_ids(self):
        from crew import doctor
        return {e["id"] for e in doctor.check(self.proj) if e["level"] == "error"}

    def test_personas_subset_writes_a_matching_priority(self):
        self.assertEqual(self.init(personas="pm,qa"), 0, self.err)
        self.assertEqual(self.cfg()["huddle"]["priority"], ["pm", "qa"])
        self.assertNotIn("D20", self.doctor_ids())

    def test_add_persona_opus_raises_the_cap(self):
        self.assertEqual(self.init(), 0, self.err)
        code = self.call(init.run_add_persona, id="deep", role="custom", name="Deep", consult_on="security",
                         lens="a\nb\nc", model="opus", dry_run=False)
        self.assertEqual(code, 0, self.err)
        a = [x for x in self.cfg()["agents"] if x["id"] == "deep"][0]
        self.assertGreater(a["max_budget_usd"], 1.0)
        self.assertNotIn("D19", self.doctor_ids())

    def test_model_and_effort_are_validated(self):
        self.assertEqual(self.init(), 0, self.err)
        before = self.read(".crew/crew.json")
        self.assertEqual(self.call(init.run_add_persona, id="inj", role="pm", name="Inj", consult_on="security",
                                   lens=None, model="sonnet\ntools: Bash", dry_run=False), 2)
        os.makedirs(self.p("src/ui"))
        self.assertEqual(self.call(init.run_add_component, id="ui", dir="src/ui", paths=None, name=None,
                                   model=None, effort="turbo", consult_on=None, dry_run=False), 2)
        self.assertEqual(self.read(".crew/crew.json"), before)
        self.assertFalse(os.path.exists(self.p(".claude/agents/inj.md")))

    def test_project_name_is_quoted_in_the_front_matter(self):
        self.assertEqual(self.init(project_name='Quote"Name: x #y'), 0, self.err)
        line = [l for l in self.read(".claude/agents/lead.md").splitlines() if l.startswith("description:")][0]
        text = json.loads(line[len("description:"):].strip())
        self.assertIn('Quote"Name: x #y', text)

    def test_symlinked_settings_keeps_the_link(self):
        os.makedirs(self.p(".claude"))
        shared = os.path.join(self.tmp, "shared.json")
        with open(shared, "w") as fh:
            json.dump({"model": "opus"}, fh)
        os.symlink(shared, self.p(".claude/settings.json"))
        self.assertEqual(self.init(), 0, self.err)
        self.assertTrue(os.path.islink(self.p(".claude/settings.json")))
        with open(shared) as fh:
            doc = json.load(fh)
        self.assertEqual(doc["model"], "opus")
        self.assertIn("PreToolUse", doc["hooks"])

    def test_bad_hooks_shape_exits_2(self):
        os.makedirs(self.p(".claude"))
        with open(self.p(".claude/settings.json"), "w") as fh:
            json.dump({"hooks": {"PreToolUse": [{"hooks": 5}]}}, fh)
        self.assertEqual(self.init(), 2)
        self.assertIn("hooks", self.err)
        self.assertFalse(os.path.exists(self.p(".crew/crew.json")))

    def test_install_to_an_unwritable_home_exits_1(self):
        with mock.patch.object(init, "install_kit", side_effect=OSError("read-only")):
            self.assertEqual(self.call(init.run_install, force=False), 1)
        self.assertIn("cannot install", self.err)


if __name__ == "__main__":
    unittest.main()
