from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from crew import doctor

FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "doctor")
MVP = ["D01", "D02", "D03", "D04", "D06", "D10", "D11", "D12", "D13", "D17", "D18", "D19", "D20",
       "D21", "D22", "D23", "D24"]
PHASE2 = ["D05", "D07", "D08", "D09", "D14", "D15", "D16"]
GIT_ENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
           "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull,
           # No background maintenance: it races with the cleanup of the temp folders.
           "GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "gc.auto", "GIT_CONFIG_VALUE_0": "0",
           "GIT_CONFIG_KEY_1": "maintenance.auto", "GIT_CONFIG_VALUE_1": "false"}


def git(repo, *args):
    env = dict(os.environ, **GIT_ENV)
    return subprocess.run(["git", "-C", repo] + list(args), check=True, env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True).stdout


def overlay(name, project, home):
    """Copy the files of fixture `name` over the project and the fake crew home."""
    for sub, dst in (("project", project), ("home", home)):
        src = os.path.join(FIX, name, sub)
        if os.path.isdir(src):
            shutil.copytree(src, dst, dirs_exist_ok=True)


def edit_json(path, fn):
    with open(path) as f:
        data = json.load(f)
    fn(data)
    with open(path, "w") as f:
        json.dump(data, f)


class Base(unittest.TestCase):
    def build(self, name=None, commit=True):
        """A temp git project from the passing fixture plus the overlay `name`."""
        tmp = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        self.project, self.home = os.path.join(tmp, "project"), os.path.join(tmp, "home")
        overlay("pass", self.project, self.home)
        if name:
            overlay(name, self.project, self.home)
        os.chmod(os.path.join(self.home, "bin", "crew"), 0o755)
        p = mock.patch.dict(os.environ, dict(GIT_ENV, CREW_HOME=self.home))
        p.start()
        self.addCleanup(p.stop)
        git(self.project, "init", "-q", "-b", "dev")
        if commit:
            git(self.project, "add", "-A")
            git(self.project, "commit", "-q", "-m", "base")
        return self.project

    def problems(self, entries):
        return [e for e in entries if e["level"] in ("warn", "error")]

    def crew_json(self, fn):
        edit_json(os.path.join(self.project, ".crew", "crew.json"), fn)

    def settings(self, fn):
        edit_json(os.path.join(self.project, ".claude", "settings.json"), fn)

    def only_text(self, check_id):
        bad = self.problems(doctor.check(self.project))
        self.assertEqual({e["id"] for e in bad}, {check_id}, bad)
        return " ".join(e["text"] for e in bad)

    def only(self, check_id):
        self.assertEqual({e["id"] for e in self.problems(doctor.check(self.project))}, {check_id})


class FailingFixtureTests(Base):
    def expect(self, check_id, level):
        bad = self.problems(doctor.check(self.build(check_id.lower())))
        self.assertTrue(bad, "no problem found for " + check_id)
        self.assertEqual({e["id"] for e in bad}, {check_id}, bad)
        self.assertEqual({e["level"] for e in bad}, {level}, bad)
        return bad

    def test_d01(self):
        entries = doctor.check(self.build("d01"))
        self.assertEqual([e["level"] for e in entries if e["id"] == "D01"], ["error"])
        self.assertEqual({e["level"] for e in entries if e["id"] != "D01"}, {"skip"})

    def test_d01_bad_json(self):
        project = self.build()
        with open(os.path.join(project, ".crew", "crew.json"), "w") as f:
            f.write("{nope")
        entries = doctor.check(project)
        self.assertEqual((entries[0]["id"], entries[0]["level"]), ("D01", "error"))

    def test_d01_unknown_key_warns(self):
        self.build()
        self.crew_json(lambda c: c.update(surprise=1))
        bad = self.problems(doctor.check(self.project))
        self.assertEqual([(e["id"], e["level"]) for e in bad], [("D01", "warn")])

    def test_d02(self):
        self.expect("D02", "error")

    def test_d03(self):
        self.expect("D03", "error")

    def test_d04(self):
        self.expect("D04", "error")

    def test_d03_duplicate_front_matter_key(self):
        self.build()
        path = os.path.join(self.project, ".claude", "agents", "lead.md")
        with open(path) as fh:
            text = fh.read()
        with open(path, "w") as fh:
            fh.write(text.replace("\n---\n", "\ntools: Bash\n---\n", 1))
        bad = [e for e in doctor.check(self.project) if e["id"] == "D03" and e["level"] == "error"]
        self.assertTrue(any("twice" in e["text"] for e in bad), bad)

    def test_d06(self):
        self.expect("D06", "error")

    def test_d10(self):
        self.expect("D10", "error")

    def test_d11(self):
        bad = self.expect("D11", "error")
        self.assertIn("guard", bad[0]["text"])

    def test_d11_missing_command(self):
        self.build()
        self.settings(lambda s: s["hooks"].pop("Stop"))
        self.only("D11")

    def test_d11_guard_on_failure(self):
        self.build()
        guard = lambda s: s["hooks"]["PreToolUse"][0]["hooks"][0]
        self.settings(lambda s: guard(s).update(onFailure="allow"))
        self.only("D11")
        self.settings(lambda s: guard(s).update(onFailure="block"))
        bad = self.problems(doctor.check(self.project))
        self.assertEqual([(e["id"], e["level"]) for e in bad], [("D11", "warn")])

    def test_d11_guard_matcher_must_cover_edit_and_write(self):
        self.build()
        self.settings(lambda s: s["hooks"]["PreToolUse"][0].update(matcher="Bash"))
        self.assertIn("matcher", self.only_text("D11"))
        self.settings(lambda s: s["hooks"]["PreToolUse"][0].update(matcher="*"))
        self.assertEqual(self.problems(doctor.check(self.project)), [])

    def test_empty_deny_words_means_no_words(self):
        self.build()
        self.crew_json(lambda c: c.setdefault("doctor", {}).update(deny_words=[]))
        self.assertEqual(self.problems(doctor.check(self.project)), [])

    def test_d18_naive_times_are_an_error(self):
        self.build()
        self.crew_json(lambda c: c["autonomy"].update(level="L4", set_at="2026-11-27T10:00:00",
                                                      expires_at="2026-11-28T10:00:00"))
        self.assertIn("offset", self.only_text("D18"))

    def test_config_load_errors_reach_d01(self):
        self.build()
        self.crew_json(lambda c: c["autonomy"].update(set_at="yesterday"))
        entries = doctor.check(self.project)
        self.assertEqual([e["level"] for e in entries if e["id"] == "D01"], ["error"])

    def test_malformed_values_never_crash(self):
        cases = [
            lambda c: c["huddle"].update(max_advisers="3"),
            lambda c: c["huddle"].update(owner_tags=None),
            lambda c: c.setdefault("gates", {}).update(rules=["x"]),
            lambda c: c.update(routing=[{"when": ["x"]}]),
            lambda c: c["project"].update(public_paths=[1]),
            lambda c: c.setdefault("doctor", {}).update(deny_words=[1]),
            lambda c: c["autonomy"].update(level="L4", set_at=5),
            lambda c: [a.update(component_dir=5) for a in c["agents"] if a.get("role") == "component"],
        ]
        for i, fn in enumerate(cases):
            self.build()
            self.crew_json(fn)
            for changed in (False, True):
                entries = doctor.check(self.project, changed_only=changed)
                self.assertTrue(any(e["id"] == "D01" and e["level"] == "error" for e in entries), i)
            shutil.rmtree(os.path.dirname(self.project), True)

    def test_safe_turns_an_exception_into_an_error(self):
        project = self.build()
        with mock.patch.dict(doctor.CHECKS, {"D21": mock.Mock(side_effect=AttributeError("x"))}):
            bad = self.problems(doctor.check(project))
        self.assertEqual([(e["id"], e["level"]) for e in bad], [("D21", "error")])
        self.assertIn("check failed", bad[0]["text"])

    def test_d12(self):
        self.expect("D12", "error")

    def test_d12_missing_shim(self):
        project = self.build()
        os.remove(os.path.join(self.home, "bin", "crew"))
        self.only("D12")

    def test_d12_timeout(self):
        project = self.build()
        real = subprocess.run

        def fake(cmd, *a, **kw):
            if cmd[0].endswith("bin/crew"):
                raise subprocess.TimeoutExpired(cmd, 5)
            return real(cmd, *a, **kw)

        with mock.patch("crew.doctor.subprocess.run", side_effect=fake):
            bad = self.problems(doctor.check(project))
        self.assertEqual([(e["id"], "timed out" in e["text"]) for e in bad], [("D12", True)])

    def test_d13(self):
        self.expect("D13", "error")

    def test_d13_not_a_git_repo(self):
        project = self.build()
        shutil.rmtree(os.path.join(project, ".git"), ignore_errors=True)
        self.assertIn("D13", {e["id"] for e in self.problems(doctor.check(project))})

    def test_d17(self):
        self.expect("D17", "error")

    def test_d18(self):
        bad = self.expect("D18", "error")
        self.assertIn("30 days", bad[0]["text"])

    def test_d18_l5_needs_expiry(self):
        self.build()
        self.crew_json(lambda c: c.update(autonomy={"level": "L5", "set_at": "2026-11-27T19:00:00+05:30"}))
        self.only("D18")

    def test_d18_l4_within_30_days_is_ok(self):
        self.build()
        self.crew_json(lambda c: c.update(autonomy={"level": "L4", "set_at": "2026-11-27T19:00:00+05:30",
                                                    "expires_at": "2026-12-20T19:00:00+05:30"}))
        self.assertEqual(self.problems(doctor.check(self.project)), [])

    def test_d19(self):
        self.expect("D19", "error")

    def test_d19_reserve_above_smallest_cap(self):
        self.build()
        self.crew_json(lambda c: c.update(budget={"call_reserve_usd": {"default": 0.6}}))  # pm cap is 0.5
        self.only("D19")

    def test_d20(self):
        self.expect("D20", "error")

    def test_d21(self):
        self.expect("D21", "error")

    def test_d22(self):
        self.expect("D22", "warn")

    def test_d22_missing_file_warns(self):
        project = self.build()
        os.remove(os.path.join(project, "ARCHITECTURE.md"))
        bad = self.problems(doctor.check(project))
        self.assertEqual([(e["id"], e["level"]) for e in bad], [("D22", "warn")])


class GitCheckTests(Base):
    def branch(self, name):
        project = self.build()
        git(project, "checkout", "-q", "-b", "feature/x")
        overlay(name, project, self.home)
        git(project, "add", "-A")
        return project

    def test_d23_warns_when_code_changes_without_docs(self):
        project = self.branch("d23")
        git(project, "commit", "-q", "-m", "add code")
        bad = self.problems(doctor.check(project))
        self.assertEqual([(e["id"], e["level"]) for e in bad], [("D23", "warn")])
        self.assertIn("c-core", bad[0]["text"])

    def test_d23_ok_when_interface_changes_too(self):
        project = self.branch("d23")
        with open(os.path.join(project, "pub", "core", "INTERFACE.md"), "a") as f:
            f.write("\nMore.\n")
        git(project, "add", "-A")
        git(project, "commit", "-q", "-m", "add code and docs")
        self.assertEqual(self.problems(doctor.check(project)), [])

    def test_d23_ok_on_the_default_branch(self):
        self.assertEqual(self.problems(doctor.check(self.build())), [])

    def test_d24_errors_on_deny_word_in_commit_message(self):
        project = self.branch("d24")
        git(project, "commit", "-q", "-m", "update Revenue forecast")
        bad = self.problems(doctor.check(project))
        self.assertEqual({(e["id"], e["level"]) for e in bad}, {("D24", "error")})
        self.assertIn("revenue", bad[0]["text"])

    def test_d24_errors_on_deny_word_in_branch_name(self):
        project = self.build()
        git(project, "checkout", "-q", "-b", "feature/revenue-forecast")
        bad = self.problems(doctor.check(project))
        self.assertEqual([(e["id"], e["level"]) for e in bad], [("D24", "error")])

    def test_nested_public_repo(self):
        project = self.build()
        # pub/ becomes its own repo, as whisper-master/ is inside the workspace root.
        pub = os.path.join(project, "pub")
        git(project, "rm", "-rq", "--cached", "pub")
        git(project, "commit", "-q", "-m", "untrack pub")
        git(pub, "init", "-q", "-b", "dev")
        git(pub, "add", "-A")
        git(pub, "commit", "-q", "-m", "base")
        git(pub, "checkout", "-q", "-b", "feature/y")
        with open(os.path.join(pub, "core", "code.py"), "w") as f:
            f.write("x = 1\n")
        git(pub, "add", "-A")
        git(pub, "commit", "-q", "-m", "add revenue code")
        bad = self.problems(doctor.check(project))
        self.assertEqual(sorted((e["id"], e["level"]) for e in bad), [("D23", "warn"), ("D24", "error")])

    def test_git_error_is_not_a_crash(self):
        project = self.build()
        with mock.patch("crew.doctor._git", return_value=(128, "")):
            self.assertTrue(doctor.check(project))


class PassingAndCliTests(Base):
    def run_cli(self, project, **kw):
        ns = dict(json=False, strict=False, changed=False)
        ns.update(kw)
        cwd = os.getcwd()
        self.addCleanup(os.chdir, cwd)
        os.chdir(project)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = doctor.run_doctor(argparse.Namespace(**ns))
        return rc, out.getvalue(), err.getvalue()

    def test_passing_project_exits_0(self):
        project = self.build()
        self.assertEqual(self.problems(doctor.check(project)), [])
        rc, out, _ = self.run_cli(project)
        self.assertEqual(rc, 0)
        self.assertIn("D01 ok", out)

    def test_json_shape_on_passing_project(self):
        rc, out, _ = self.run_cli(self.build(), json=True)
        data = json.loads(out)
        self.assertEqual((rc, data["errors"], data["warnings"]), (0, 0, 0))
        self.assertEqual(sorted({c["id"] for c in data["checks"]}), sorted(MVP + PHASE2))
        self.assertEqual(set(data["checks"][0]), {"id", "level", "path", "text"})

    def test_phase_2_checks_print_skip(self):
        _, out, _ = self.run_cli(self.build())
        for cid in PHASE2:
            self.assertIn("%s skip" % cid, out.splitlines())

    def test_line_format(self):
        rc, out, _ = self.run_cli(self.build("d22"))
        self.assertEqual(rc, 0)
        self.assertRegex(out, r"(?m)^D22 warn ARCHITECTURE\.md: ")

    def test_exit_7_on_error(self):
        self.assertEqual(self.run_cli(self.build("d21"))[0], 7)

    def test_strict_turns_warning_into_error(self):
        project = self.build("d22")
        self.assertEqual(self.run_cli(project)[0], 0)
        rc, out, _ = self.run_cli(project, strict=True)
        self.assertEqual(rc, 7)
        self.assertRegex(out, r"(?m)^D22 error ")

    def test_changed_runs_only_d23_and_d24(self):
        project = self.build("d21")  # a D21 error that --changed must not see
        rc, out, _ = self.run_cli(project, changed=True, json=True)
        self.assertEqual(rc, 0)
        self.assertEqual(sorted({c["id"] for c in json.loads(out)["checks"]}), ["D23", "D24"])

    def test_changed_does_not_run_the_shim_or_other_checks(self):
        project = self.build()
        with mock.patch.dict(doctor.CHECKS, {"D12": mock.Mock(side_effect=AssertionError("ran"))}):
            self.assertEqual(self.run_cli(project, changed=True)[0], 0)

    def test_changed_still_reports_a_broken_config(self):
        self.assertEqual(self.run_cli(self.build("d01"), changed=True)[0], 7)

    def test_not_in_a_project_exits_8(self):
        probe = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, probe, True)
        self.assertEqual(self.run_cli(probe)[0], 8)


if __name__ == "__main__":
    unittest.main()
