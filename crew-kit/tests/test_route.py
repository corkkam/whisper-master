from __future__ import annotations

import argparse
import contextlib
import copy
import io
import json
import os
import shutil
import tempfile
import unittest

from crew import config, route as route_mod

SRC = "whisper-master/Sources/WhisperMaster/"
CFG = {
    "version": 1,
    "project": {"name": "t", "public_paths": []},
    "lead": "lead",
    "agents": [
        {"id": "lead", "role": "lead"},
        {"id": "pm", "role": "pm", "consult_on": ["user-facing", "pricing", "release"]},
        {"id": "qa", "role": "qa", "consult_on": ["release"], "paths": ["whisper-master/Tests/"]},
        {"id": "design", "role": "design", "consult_on": ["user-facing"]},
        {"id": "marketing", "role": "marketing", "consult_on": ["user-facing", "launch"]},
        {"id": "user", "role": "user", "consult_on": ["user-facing"]},
        {"id": "architect", "role": "architect", "consult_on": ["security"]},
        {"id": "scout", "role": "helper"},
        {"id": "c-input", "role": "component",
         "paths": [SRC + "Input/", "whisper-master/Tests/WhisperMasterTests/Hotkey*"]},
        {"id": "c-ui", "role": "component", "paths": [SRC + "UI/"]},
    ],
    "gates": {"tags": ["data-format", "public-api", "privacy", "security", "user-facing", "pricing",
                       "release", "irreversible", "launch"],
              "rules": [{"tag": "security", "paths": [SRC + "Auth/"]}]},
    "routing": [{"when": {"type": "qa"}, "assign": "qa", "consult": ["pm"]}],
    "autonomy": {"level": "L2", "set_at": "2026-11-27T19:00:00+05:30"},
    "huddle": {"max_advisers": 3, "max_subjects": 3,
               "priority": ["pm", "user", "design", "marketing", "qa", "architect"],
               "owner_tags": ["privacy", "security", "pricing", "release", "irreversible"]},
}
KEYS = ["type", "assignees", "subjects", "gate_tags", "forced", "advisers", "skipped", "huddle",
        "split_required", "owner_gate", "reason"]


def cfg_with(**kw):
    c = copy.deepcopy(CFG)
    c.update(kw)
    return c


class RouteTests(unittest.TestCase):
    def test_example_a_qa_task(self):
        out = route_mod.route(CFG, "qa", ["whisper-master/Tests/WhisperMasterTests/HotkeyGestureTests.swift"], [])
        self.assertEqual(out, {
            "type": "qa", "assignees": ["qa"], "subjects": ["c-input"], "gate_tags": [], "forced": ["pm"],
            "advisers": ["pm"], "skipped": [], "huddle": True, "split_required": False, "owner_gate": False,
            "reason": ["rule 0: type qa -> assign qa, consult pm"]})
        self.assertEqual(list(out), KEYS)

    def test_spec_6_3_output(self):
        out = route_mod.route(CFG, "qa", [], [])
        self.assertEqual(json.dumps(out), json.dumps({
            "type": "qa", "assignees": ["qa"], "subjects": [], "gate_tags": [], "forced": ["pm"],
            "advisers": ["pm"], "skipped": [], "huddle": True, "split_required": False, "owner_gate": False,
            "reason": ["rule 0: type qa -> assign qa, consult pm"]}))

    def test_example_b_user_facing(self):
        out = route_mod.route(CFG, "code", [SRC + "Input/HotkeyHint.swift"], ["user-facing"])
        self.assertEqual(out["assignees"], ["c-input"])
        self.assertEqual(out["subjects"], ["c-input"])
        self.assertEqual(out["gate_tags"], ["user-facing"])
        self.assertEqual(out["advisers"], ["pm", "user", "design"])
        self.assertEqual(out["skipped"], ["marketing"])
        self.assertTrue(out["huddle"])
        self.assertFalse(out["owner_gate"])

    def test_max_advisers_four_keeps_marketing(self):
        c = cfg_with(huddle=dict(CFG["huddle"], max_advisers=4))
        out = route_mod.route(c, "code", [SRC + "Input/HotkeyHint.swift"], ["user-facing"])
        self.assertEqual(out["advisers"], ["pm", "user", "design", "marketing"])
        self.assertEqual(out["skipped"], [])

    def test_tie_rule_unlisted_ids_sort_by_id_after_listed(self):
        c = copy.deepcopy(CFG)
        c["agents"] += [{"id": "zeta", "role": "custom", "consult_on": ["user-facing"]},
                        {"id": "alpha", "role": "custom", "consult_on": ["user-facing"]}]
        c["huddle"]["max_advisers"] = 10
        out = route_mod.route(c, "docs", [], ["user-facing"])
        self.assertEqual(out["advisers"], ["pm", "user", "design", "marketing", "alpha", "zeta"])

    def test_consult_capped(self):
        c = copy.deepcopy(CFG)
        c["routing"] = [{"when": {"type": "qa"}, "assign": "qa", "consult": ["pm", "user", "design", "marketing"]}]
        out = route_mod.route(c, "qa", [], [])
        self.assertEqual(out["forced"], ["pm", "user", "design", "marketing"])
        self.assertEqual(out["advisers"], ["pm", "user", "design"])
        self.assertEqual(out["skipped"], ["marketing"])
        self.assertIn("consult capped", out["reason"])

    def test_split_required_above_max_subjects(self):
        c = copy.deepcopy(CFG)
        c["agents"] += [{"id": "c-%s" % n, "role": "component", "paths": ["%s/" % n]} for n in "abcd"]
        out = route_mod.route(c, "code", ["a/x", "b/x", "c/x", "d/x"], [])
        self.assertTrue(out["split_required"])
        self.assertEqual(out["subjects"], ["c-a", "c-b", "c-c", "c-d"])
        out = route_mod.route(c, "code", ["a/x", "b/x", "c/x"], [])
        self.assertFalse(out["split_required"])

    def test_owner_gate_for_security_path(self):
        out = route_mod.route(CFG, "code", [SRC + "Auth/Session.swift"], [])
        self.assertEqual(out["gate_tags"], ["security"])
        self.assertTrue(out["owner_gate"])
        self.assertEqual(out["advisers"], ["architect"])
        self.assertTrue(out["huddle"])

    def test_example_b_reason_explains_steps_5_9_11(self):
        out = route_mod.route(CFG, "code", [SRC + "Input/HotkeyHint.swift"], ["user-facing"])
        self.assertEqual(out["reason"], [
            "assignee from component paths: c-input",
            "consult_on matched: pm, user, design, marketing",
            "advisers skipped over the limit of 3: marketing"])

    def test_no_component_falls_back_to_lead(self):
        out = route_mod.route(CFG, "ops", ["other/file"], [])
        self.assertEqual(out["assignees"], ["lead"])
        self.assertFalse(out["huddle"])

    def test_rule_gates_added_and_not_retested(self):
        c = copy.deepcopy(CFG)
        c["routing"] = [{"when": {"type": "copy"}, "assign": "marketing", "gates": ["user-facing"]},
                        {"when": {"tags_any": ["user-facing"]}, "consult": ["qa"]}]
        out = route_mod.route(c, "copy", [], [])
        self.assertEqual(out["gate_tags"], ["user-facing"])
        self.assertEqual(out["forced"], [])  # rule 1 saw no tag at step 4
        self.assertEqual(out["assignees"], ["marketing"])

    def test_invalid_input_raises(self):
        with self.assertRaises(ValueError):
            route_mod.route(CFG, "bogus", [], [])
        with self.assertRaises(ValueError):
            route_mod.route(CFG, "code", [], ["not-a-tag"])


class ProjectCase(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        os.makedirs(os.path.join(self.tmp, ".crew"))
        with open(os.path.join(self.tmp, ".crew", "crew.json"), "w") as f:
            json.dump(CFG, f)
        self.cwd = os.getcwd()
        self.addCleanup(os.chdir, self.cwd)
        os.chdir(self.tmp)

    def run_cli(self, **kw):
        ns = dict(type=None, paths="", tags="", task=None, part=1, json=False)
        ns.update(kw)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = route_mod.run_route(argparse.Namespace(**ns))
        return rc, out.getvalue(), err.getvalue()


class SavePartTests(ProjectCase):
    def route_file(self, task):
        with open(os.path.join(self.tmp, ".crew", "tasks", task, "route.json")) as f:
            return json.load(f)

    def test_save_part_merges_two_parts(self):
        p1 = route_mod.route(CFG, "code", [SRC + "UI/A.swift"], ["user-facing"])
        p2 = route_mod.route(CFG, "code", [SRC + "Auth/S.swift"], [])
        route_mod.save_part(self.tmp, "t-1", 1, p1)
        doc = route_mod.save_part(self.tmp, "t-1", 2, p2)
        self.assertEqual(doc["gate_tags"], ["security", "user-facing"])  # gates.tags order
        self.assertTrue(doc["owner_gate"])
        self.assertEqual(sorted(doc["parts"]), ["1", "2"])
        self.assertEqual(self.route_file("t-1"), doc)
        self.assertEqual(doc["task_id"], "t-1")
        self.assertEqual(sorted(os.listdir(os.path.join(self.tmp, ".crew", "tasks", "t-1"))),
                         ["route.json", "route.lock"])

    def test_owner_gate_false_when_no_part_has_it(self):
        p1 = route_mod.route(CFG, "code", [SRC + "UI/A.swift"], ["user-facing"])
        doc = route_mod.save_part(self.tmp, "t-2", 1, p1)
        self.assertFalse(doc["owner_gate"])

    def test_bad_task_id_and_part(self):
        out = route_mod.route(CFG, "qa", [], [])
        for bad in ("../x", "a/b", ""):
            with self.assertRaises(ValueError):
                route_mod.save_part(self.tmp, bad, 1, out)
        with self.assertRaises(ValueError):
            route_mod.save_part(self.tmp, "t-3", 0, out)


class RunRouteTests(ProjectCase):
    def test_json_output_and_exit_0(self):
        rc, out, _ = self.run_cli(type="qa", json=True)
        self.assertEqual(rc, 0)
        self.assertEqual(list(json.loads(out)), KEYS)

    def test_plain_output_one_line_per_key(self):
        rc, out, _ = self.run_cli(type="qa", paths="a,b")
        self.assertEqual(rc, 0)
        lines = out.strip().split("\n")
        self.assertEqual([l.split(":")[0] for l in lines], KEYS)
        self.assertIn("advisers: [\"pm\"]", lines)

    def test_invalid_tag_exits_2(self):
        rc, out, err = self.run_cli(type="code", tags="nope")
        self.assertEqual((rc, out), (2, ""))
        self.assertIn("invalid tag", err)

    def test_invalid_type_exits_2(self):
        self.assertEqual(self.run_cli(type="zzz")[0], 2)

    def test_task_saves_and_prints_only_this_part(self):
        rc, out, _ = self.run_cli(type="code", paths=SRC + "Auth/S.swift", task="t-9", part=2, json=True)
        self.assertEqual(rc, 0)
        self.assertEqual(list(json.loads(out)), KEYS)
        with open(os.path.join(self.tmp, ".crew", "tasks", "t-9", "route.json")) as f:
            self.assertIn("2", json.load(f)["parts"])

    def test_malformed_config_exits_2_without_a_traceback(self):
        c = copy.deepcopy(CFG)
        c["huddle"]["max_advisers"] = "3"
        with open(os.path.join(self.tmp, ".crew", "crew.json"), "w") as f:
            json.dump(c, f)
        rc, out, err = self.run_cli(type="code", paths=SRC + "UI/A.swift", tags="user-facing")
        self.assertEqual((rc, out), (2, ""))
        self.assertIn("bad crew.json", err)

    def test_corrupt_route_json_is_reported_not_dropped(self):
        d = os.path.join(self.tmp, ".crew", "tasks", "t-bad")
        os.makedirs(d)
        with open(os.path.join(d, "route.json"), "w") as f:
            f.write("{nope")
        rc, _, err = self.run_cli(type="qa", task="t-bad")
        self.assertEqual(rc, 2)
        self.assertIn("corrupt", err)
        with open(os.path.join(d, "route.json")) as f:
            self.assertEqual(f.read(), "{nope")

    def test_no_project_exits_8(self):
        os.chdir(tempfile.gettempdir())
        probe = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, probe, True)
        os.chdir(probe)
        self.assertEqual(self.run_cli(type="qa")[0], 8)

    def test_paths_are_normalized_before_the_gate_rules(self):
        for p in ("./" + SRC + "Auth/S.swift", os.path.join(self.tmp, SRC, "Auth/S.swift"),
                  SRC + "UI/../Auth/S.swift", ".claude/worktrees/foo/" + SRC + "Auth/S.swift"):
            rc, out, err = self.run_cli(type="code", paths=p, json=True)
            self.assertEqual(rc, 0, err)
            self.assertEqual(json.loads(out)["gate_tags"], ["security"], p)
            self.assertTrue(json.loads(out)["owner_gate"], p)

    def test_path_outside_the_project_exits_2(self):
        for p in ("../x/a.swift", "/etc/passwd"):
            rc, out, err = self.run_cli(type="code", paths=p)
            self.assertEqual((rc, out), (2, ""), p)
            self.assertIn("outside the project", err)

    def test_part_below_1_and_empty_task_exit_2(self):
        for kw in (dict(task="t-p", part=0), dict(task="t-p", part=-3), dict(task="")):
            rc, out, err = self.run_cli(type="code", **kw)
            self.assertEqual((rc, out), (2, ""), kw)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, ".crew", "tasks", "t-p")))


if __name__ == "__main__":
    unittest.main()
