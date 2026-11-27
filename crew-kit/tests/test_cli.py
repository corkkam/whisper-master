from __future__ import annotations

import contextlib
import io
import os
import subprocess
import sys
import types
import unittest
from unittest import mock

from crew import __version__, cli

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(KIT, "bin", "crew")


def run_bin(*args, stdin=""):
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    return subprocess.run([sys.executable, BIN] + list(args), input=stdin, capture_output=True,
                          text=True, env=env, timeout=30)


class TestBin(unittest.TestCase):
    def test_version(self):
        r = run_bin("--version")
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "crew 0.1.0"))
        self.assertEqual(__version__, "0.1.0")

    def test_version_through_a_symlink(self):
        import shutil
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        link = os.path.join(d, "crew")
        os.symlink(BIN, link)
        r = subprocess.run([sys.executable, link, "--version"], capture_output=True, text=True, timeout=30)
        self.assertEqual(r.stdout.strip(), "crew 0.1.0")

    def test_route_help_lists_the_flags(self):
        r = run_bin("route", "--help")
        self.assertEqual(r.returncode, 0)
        for flag in ("--type", "--paths", "--tags", "--task", "--part", "--json"):
            self.assertIn(flag, r.stdout)

    def test_usage_errors_exit_2(self):
        self.assertEqual(run_bin().returncode, 2)
        self.assertEqual(run_bin("nope").returncode, 2)
        self.assertEqual(run_bin("route").returncode, 2)  # --type is required
        r = run_bin("hook")  # a hook never blocks: exit 0, no output
        self.assertEqual((r.returncode, r.stderr), (0, ""))

    def test_is_executable(self):
        self.assertTrue(os.access(BIN, os.X_OK))
        with open(BIN) as fh:
            self.assertEqual(fh.readline().strip(), "#!/usr/bin/env python3")


class TestParsers(unittest.TestCase):
    def parse(self, *argv):
        return cli.build_parser().parse_args(list(argv))

    def test_init(self):
        a = self.parse("init", "--lead-name", "Atlas", "--project-name", "p", "--personas", "pm,qa",
                       "--no-helper", "--no-agents-block", "--dry-run", "--force")
        self.assertEqual((a.command, a.lead_name, a.project_name, a.personas), ("init", "Atlas", "p", "pm,qa"))
        self.assertTrue(a.no_helper and a.no_agents_block and a.dry_run and a.force)
        a = self.parse("init")
        self.assertEqual(a.personas, "pm,qa,design,marketing,user,architect")
        self.assertFalse(a.force)

    def test_install_and_components(self):
        self.assertTrue(self.parse("install", "--force").force)
        a = self.parse("add-component", "input", "--dir", "Sources/Input", "--paths", "a/,b/", "--name", "Tapper",
                       "--model", "sonnet", "--effort", "high", "--consult-on", "privacy,security", "--dry-run")
        self.assertEqual((a.id, a.dir, a.paths, a.name, a.consult_on), ("input", "Sources/Input", "a/,b/", "Tapper",
                                                                         "privacy,security"))
        a = self.parse("add-persona", "sec", "--name", "Sam", "--consult-on", "security", "--lens", "x")
        self.assertEqual((a.role, a.model, a.lens), ("custom", "sonnet", "x"))
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                self.parse("add-component", "input")
            with self.assertRaises(SystemExit):
                self.parse("add-persona", "x", "--name", "N")

    def test_doctor_route(self):
        a = self.parse("doctor", "--json", "--strict", "--changed")
        self.assertTrue(a.json and a.strict and a.changed)
        a = self.parse("route", "--type", "code", "--paths", "a,b", "--tags", "privacy", "--task", "t1",
                       "--part", "2", "--json")
        self.assertEqual((a.type, a.paths, a.tags, a.task, a.part, a.json), ("code", "a,b", "privacy", "t1", 2, True))

    def test_run_and_loop(self):
        a = self.parse("run", "do it", "--file", "f", "--agent", "qa", "--task-id", "t", "--approved", "--auto",
                       "--max-usd", "0.5", "--quiet", "--dry-run", "--json")
        self.assertEqual((a.task, a.file, a.agent, a.task_id, a.max_usd), ("do it", "f", "qa", "t", 0.5))
        self.assertTrue(a.approved and a.auto and a.quiet and a.dry_run and a.json)
        self.assertIsNone(self.parse("run", "--file", "f").task)
        a = self.parse("loop", "goal", "--until", "18:30", "--max-iterations", "3", "--max-usd", "2", "--window", "50")
        self.assertEqual((a.goal, a.until, a.max_iterations, a.max_usd, a.window), ("goal", "18:30", 3, 2.0, 50.0))
        self.assertEqual(self.parse("loop", "--backlog").max_iterations, 5)
        self.assertTrue(self.parse("loop", "--improve").improve)

    def test_budget_status_memory(self):
        a = self.parse("budget", "--json", "--task", "t", "--runs", "4", "--probe")
        self.assertEqual((a.json, a.task, a.runs, a.probe), (True, "t", 4, True))
        self.assertTrue(self.parse("status", "--json").json)
        a = self.parse("memory", "qa", "--json")
        self.assertEqual((a.agent, a.json), ("qa", True))

    def test_control(self):
        self.assertEqual(self.parse("check-public", "--text-file", "x").text_file, "x")
        a = self.parse("stop", "--global", "--reason", "owner")
        self.assertEqual((a.global_, a.reason), (True, "owner"))
        self.assertFalse(self.parse("resume").global_)
        self.assertTrue(self.parse("resume", "--global").global_)
        a = self.parse("autonomy", "L5", "--days", "3")
        self.assertEqual((a.level, a.days), ("L5", 3))
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                self.parse("autonomy", "L6")
        a = self.parse("emit", "huddle.start", "--agent", "nova", "--agents", "pm,qa", "--task", "t",
                       "--note", "round 2", "--session", "s")
        self.assertEqual((a.event, a.agent, a.agents, a.task, a.note, a.session),
                         ("huddle.start", "nova", "pm,qa", "t", "round 2", "s"))
        self.assertTrue(self.parse("statusline", "--install").install)

    def test_hooks(self):
        for h in ("event", "guard", "session-start"):
            a = self.parse("hook", h)
            self.assertEqual((a.command, a.hook_command), ("hook", h))

    def test_every_command_has_a_handler(self):
        parser = cli.build_parser()
        sub = [a for a in parser._actions if a.dest == "command"][0]
        names = set(sub.choices) - {"hook"}
        self.assertEqual(names, {k for k in cli.HANDLERS if not k.startswith("hook ")})
        self.assertEqual({k for k in cli.HANDLERS if k.startswith("hook ")},
                         {"hook event", "hook guard", "hook session-start"})


class TestDispatch(unittest.TestCase):
    def fake(self, name, func, result):
        mod = types.ModuleType("crew." + name)
        calls = []
        setattr(mod, func, lambda args: calls.append(args) or result)
        return mock.patch.dict(sys.modules, {"crew." + name: mod}), calls

    def test_calls_the_handler_and_returns_its_code(self):
        patch, calls = self.fake("route", "run_route", 7)
        with patch:
            self.assertEqual(cli.main(["route", "--type", "qa"]), 7)
        self.assertEqual(calls[0].type, "qa")

    def test_none_means_zero(self):
        patch, _ = self.fake("doctor", "run_doctor", None)
        with patch:
            self.assertEqual(cli.main(["doctor"]), 0)

    def test_module_map(self):
        expect = {
            ("init",): ("init", "run_init"), ("install",): ("init", "run_install"),
            ("add-component", "x", "--dir", "d"): ("init", "run_add_component"),
            ("add-persona", "x", "--name", "n", "--consult-on", "privacy"): ("init", "run_add_persona"),
            ("doctor",): ("doctor", "run_doctor"), ("route", "--type", "qa"): ("route", "run_route"),
            ("run", "t"): ("runner", "run_run"), ("loop", "g"): ("runner", "run_loop"),
            ("budget",): ("budget", "run_budget"), ("statusline",): ("budget", "run_statusline"),
            ("status",): ("control", "run_status"), ("stop",): ("control", "run_stop"),
            ("resume",): ("control", "run_resume"), ("emit", "huddle.end", "--agent", "a"): ("control", "run_emit"),
            ("memory", "qa"): ("control", "run_memory"), ("check-public", "--text-file", "f"): ("control", "run_check_public"),
            ("autonomy", "L2"): ("control", "run_autonomy"),
            ("hook", "event"): ("hooks", "run_hook_event"), ("hook", "guard"): ("guard", "run_hook_guard"),
            ("hook", "session-start"): ("hooks", "run_hook_session_start"),
        }
        for argv, (mod, func) in expect.items():
            patch, calls = self.fake(mod, func, 0)
            with patch:
                self.assertEqual(cli.main(list(argv)), 0, argv)
            self.assertEqual(len(calls), 1, argv)

    def test_missing_module_exits_2(self):
        with mock.patch.dict(cli.HANDLERS, {"doctor": ("no_such_module_xyz", "run_doctor")}):
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                self.assertEqual(cli.main(["doctor"]), 2)
        self.assertEqual(err.getvalue(), "crew: doctor is not built yet\n")

    def test_missing_function_exits_2(self):
        mod = types.ModuleType("crew.doctor")
        with mock.patch.dict(sys.modules, {"crew.doctor": mod}):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cli.main(["doctor"]), 2)

    def test_other_import_errors_are_not_hidden(self):
        class Boom(types.ModuleType):
            def __getattr__(self, name):
                raise ModuleNotFoundError("No module named 'zzz'", name="zzz")
        with mock.patch.dict(sys.modules, {"crew.doctor": Boom("crew.doctor")}):
            with self.assertRaises(ModuleNotFoundError):
                cli.main(["doctor"])

    def test_hook_never_fails(self):
        with mock.patch.dict(cli.HANDLERS, {"hook guard": ("no_such_module_xyz", "run_hook_guard")}):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cli.main(["hook", "guard"]), 0)
        mod = types.ModuleType("crew.hooks")
        mod.run_hook_event = lambda a: 1 / 0
        with mock.patch.dict(sys.modules, {"crew.hooks": mod}):
            self.assertEqual(cli.main(["hook", "event"]), 0)

    def test_hook_prints_nothing_to_stderr(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            with mock.patch.dict(cli.HANDLERS, {"hook guard": ("no_such_module_xyz", "run_hook_guard")}):
                self.assertEqual(cli.main(["hook", "guard"]), 0)
            self.assertEqual(cli.main(["hook", "no-such-hook"]), 0)  # an older kit: never exit 2
        self.assertEqual(err.getvalue(), "")

    def test_a_bad_import_inside_a_module_is_not_hidden(self):
        with mock.patch.object(cli.importlib, "import_module", side_effect=ImportError("cannot import name x")):
            with self.assertRaises(ImportError):
                cli.main(["doctor"])
        with mock.patch.object(cli.importlib, "import_module", side_effect=AttributeError("boom")):
            with self.assertRaises(AttributeError):
                cli.main(["doctor"])


class TestInputChecks(unittest.TestCase):
    def test_bad_flag_values_exit_2(self):
        for argv in (["run", "x", "--max-usd", "-1"], ["run", "x", "--max-usd", "0"],
                     ["loop", "g", "--max-usd", "-1"], ["loop", "g", "--max-usd", "nan"],
                     ["route", "--type", "code", "--part", "0"], ["route", "--type", "code", "--part", "-2"],
                     ["add-component", "x", "--dir", "d", "--effort", "turbo"]):
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as cm:
                    cli.build_parser().parse_args(argv)
            self.assertEqual(cm.exception.code, 2, argv)

    def test_good_flag_values_parse(self):
        a = cli.build_parser().parse_args(["run", "x", "--max-usd", "0.01"])
        self.assertEqual(a.max_usd, 0.01)
        a = cli.build_parser().parse_args(["add-component", "x", "--dir", "d", "--effort", "xhigh"])
        self.assertEqual(a.effort, "xhigh")


if __name__ == "__main__":
    unittest.main()
