from __future__ import annotations

import inspect
import json
import os
import shutil
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

from crew import config

FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "crew.json")

# (name, kind, default) for every parameter, from spec section 13.7.
E = inspect.Parameter.empty
SIGNATURES = {
    "crew_home": [],
    "find_project": [("start", "POSITIONAL_OR_KEYWORD", E)],
    "load": [("project", "POSITIONAL_OR_KEYWORD", E)],
    "agent": [("cfg", "POSITIONAL_OR_KEYWORD", E), ("agent_id", "POSITIONAL_OR_KEYWORD", E)],
    "account": [("cfg", "POSITIONAL_OR_KEYWORD", E)],
    "path_matches": [("rel", "POSITIONAL_OR_KEYWORD", E), ("pattern", "POSITIONAL_OR_KEYWORD", E)],
    "rel_path": [("project", "POSITIONAL_OR_KEYWORD", E), ("path", "POSITIONAL_OR_KEYWORD", E),
                 ("cwd", "POSITIONAL_OR_KEYWORD", E)],
    "is_protected": [("cfg", "POSITIONAL_OR_KEYWORD", E), ("rel", "POSITIONAL_OR_KEYWORD", E)],
    "stop_set": [("project", "POSITIONAL_OR_KEYWORD", E)],
    "ledger_lock": [("project", "POSITIONAL_OR_KEYWORD", E)],
    "append_ledger": [("project", "POSITIONAL_OR_KEYWORD", E), ("row", "POSITIONAL_OR_KEYWORD", E)],
    "read_ledger": [("project", "POSITIONAL_OR_KEYWORD", E), ("tail_bytes", "POSITIONAL_OR_KEYWORD", None)],
    "spent": [("rows", "POSITIONAL_OR_KEYWORD", E), ("day", "KEYWORD_ONLY", None),
              ("task_id", "KEYWORD_ONLY", None), ("loop_id", "KEYWORD_ONLY", None)],
    "effective_level": [("cfg", "POSITIONAL_OR_KEYWORD", E), ("rows", "POSITIONAL_OR_KEYWORD", E),
                        ("now", "POSITIONAL_OR_KEYWORD", None)],
    "session_file": [("session_id", "POSITIONAL_OR_KEYWORD", E)],
    "read_session": [("session_id", "POSITIONAL_OR_KEYWORD", E)],
    "write_session": [("session_id", "POSITIONAL_OR_KEYWORD", E), ("data", "POSITIONAL_OR_KEYWORD", E)],
    "resolve_project": [("hook", "POSITIONAL_OR_KEYWORD", E), ("env", "POSITIONAL_OR_KEYWORD", E)],
    "resolve_agent": [("hook", "POSITIONAL_OR_KEYWORD", E), ("cfg", "POSITIONAL_OR_KEYWORD", E),
                      ("env", "POSITIONAL_OR_KEYWORD", E)],
    "utc_ts": [],
}


def mk_project(root, cfg=None):
    os.makedirs(os.path.join(root, ".crew"), exist_ok=True)
    if cfg is None:
        shutil.copy(FIXTURE, os.path.join(root, ".crew", "crew.json"))
    else:
        with open(os.path.join(root, ".crew", "crew.json"), "w") as fh:
            json.dump(cfg, fh)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        self.proj = os.path.join(self.tmp, "proj")
        os.makedirs(self.proj)
        p = mock.patch.dict(os.environ, {"CREW_HOME": self.home})
        p.start()
        self.addCleanup(p.stop)
        for k in ("CREW_PROJECT", "CREW_AGENT", "CREW_ACCOUNT", "CLAUDE_CONFIG_DIR"):
            os.environ.pop(k, None)


class TestApi(unittest.TestCase):
    def test_names_and_signatures(self):
        for name in ("DEFAULTS", "BUILTIN_PROTECTED", "TIER_B"):
            self.assertTrue(hasattr(config, name), name)
        for name, want in SIGNATURES.items():
            sig = inspect.signature(getattr(config, name))
            got = [(p.name, p.kind.name, p.default)
                   for p in sig.parameters.values()]
            self.assertEqual(got, want, name)

    def test_protected_order(self):
        self.assertEqual(config.BUILTIN_PROTECTED[0], ".crew/crew.json")
        self.assertEqual(config.BUILTIN_PROTECTED[-1], "**/.github/workflows/")
        self.assertEqual(len(config.BUILTIN_PROTECTED), 18)
        # review kit-safety 5: only crew route writes route.json
        self.assertTrue(config.is_protected({}, ".crew/tasks/t1/route.json"))
        self.assertFalse(config.is_protected({}, ".crew/tasks/t1/notes.md"))
        self.assertEqual(config.TIER_B, [".claude/agents/", ".claude/skills/", "AGENTS.md"])


class TestLoad(Base):
    def test_fixture_loads_clean_and_fills_defaults(self):
        mk_project(self.proj)
        cfg, errors = config.load(self.proj)
        self.assertEqual(errors, [])
        self.assertEqual(cfg["lead"], "nova")
        self.assertEqual(cfg["huddle"]["owner_tags"], ["privacy", "security", "pricing", "release", "irreversible"])
        self.assertEqual(cfg["budget"]["call_reserve_usd"], {"opus": 1.0, "default": 0.3})
        self.assertEqual(cfg["budget"]["snapshot_max_age_auto_s"], 120)
        self.assertIs(cfg["budget"]["overage_guard_verified"], False)
        self.assertEqual(cfg["context"]["max_turns"], 8)
        self.assertIn("launch", cfg["gates"]["tags"])

    def test_defaults_fill_a_minimal_file(self):
        mk_project(self.proj, {"version": 1, "project": {"name": "x"}, "lead": "a",
                               "agents": [{"id": "a", "role": "lead"}], "budget": {"per_day_usd": 4},
                               "autonomy": {"level": "L2", "set_at": "2026-11-27T19:00:00+05:30"}})
        cfg, errors = config.load(self.proj)
        self.assertEqual(errors, [])
        self.assertEqual(cfg["budget"]["per_day_usd"], 4)
        self.assertEqual(cfg["budget"]["per_task_usd"], 3.0)
        self.assertEqual(cfg["project"]["public_paths"], [])
        self.assertEqual(cfg["autonomy"]["level"], "L2")
        self.assertEqual(cfg["budget"]["max_five_hour_pct"], 90)
        self.assertEqual(cfg["budget"]["max_seven_day_pct"], 80)
        # The defaults object is not changed by a load.
        self.assertEqual(config.DEFAULTS["budget"]["per_day_usd"], 10.0)

    def test_bad_json(self):
        os.makedirs(os.path.join(self.proj, ".crew"))
        with open(os.path.join(self.proj, ".crew", "crew.json"), "w") as fh:
            fh.write("{not json")
        cfg, errors = config.load(self.proj)
        self.assertEqual(cfg, {})
        self.assertEqual(len(errors), 1)

    def test_spec_budget_names_fill_the_code_names(self):
        mk_project(self.proj)  # the fixture uses five_hour_max_pct 70
        cfg, errors = config.load(self.proj)
        self.assertEqual(errors, [])
        self.assertEqual(cfg["budget"]["max_five_hour_pct"], 70)
        self.assertEqual(cfg["budget"]["max_seven_day_pct"], 80)
        self.assertNotIn("five_hour_max_pct", config.DEFAULTS["budget"])
        base = {"version": 1, "project": {"name": "x"}, "lead": "a", "agents": [{"id": "a"}],
                "autonomy": {"level": "L2", "set_at": "2026-11-27T19:00:00Z"}}
        mk_project(self.proj, dict(base, budget={"five_hour_max_pct": 50, "max_five_hour_pct": 60}))
        self.assertEqual(config.load(self.proj)[0]["budget"]["max_five_hour_pct"], 60)

    def test_version_and_set_at_are_required(self):
        base = {"project": {"name": "x"}, "lead": "a", "agents": [{"id": "a"}],
                "autonomy": {"level": "L2", "set_at": "2026-11-27T19:00:00Z"}}
        mk_project(self.proj, base)
        self.assertEqual(config.load(self.proj)[1], ["version must be 1"])
        for bad in ({"level": "L2"}, {"level": "L2", "set_at": "yesterday"}):
            mk_project(self.proj, dict(base, version=1, autonomy=bad))
            errors = config.load(self.proj)[1]
            self.assertEqual(len(errors), 1)
            self.assertIn("set_at", errors[0])

    def test_missing_file_and_wrong_shapes(self):
        self.assertEqual(config.load(self.proj)[0], {})
        mk_project(self.proj, [1])
        self.assertEqual(config.load(self.proj)[0], {})
        mk_project(self.proj, {"version": 2, "project": {}, "lead": "zz", "agents": []})
        _, errors = config.load(self.proj)
        self.assertEqual(len(errors), 4)  # version, project.name, lead, autonomy.set_at


class TestPaths(Base):
    def test_prefix_form(self):
        self.assertTrue(config.path_matches("Tests/a/b.swift", "Tests/"))
        self.assertFalse(config.path_matches("Testsuite/a", "Tests/"))
        self.assertTrue(config.path_matches(".crew/evals/x", ".crew/evals/"))

    def test_any_depth_directory(self):
        self.assertTrue(config.path_matches("whisper-master/crew-kit/crew/guard.py", "**/crew-kit/"))
        self.assertTrue(config.path_matches("crew-kit/x.py", "**/crew-kit/"))
        self.assertFalse(config.path_matches("whisper-master/crew-kitten/x.py", "**/crew-kit/"))
        self.assertTrue(config.path_matches("whisper-master/.github/workflows/ci.yml", "**/.github/workflows/"))
        self.assertFalse(config.path_matches("a/workflows/.github/x", "**/.github/workflows/"))

    def test_any_depth_file(self):
        self.assertTrue(config.path_matches("a/b/.mcp.json", "**/.mcp.json"))
        self.assertTrue(config.path_matches(".mcp.json", "**/.mcp.json"))
        self.assertFalse(config.path_matches("a/b/x.mcp.json", "**/.mcp.json"))
        self.assertTrue(config.path_matches("w/.claude/settings.json", "**/.claude/settings.json"))
        self.assertTrue(config.path_matches("w/.claude/settings.local.json", "**/.claude/settings.local.json"))

    def test_glob_form(self):
        self.assertTrue(config.path_matches("server/tests/api_users.py", "server/tests/api_*"))
        self.assertTrue(config.path_matches("server/tests/api_x/y.py", "server/tests/api_*"))  # * matches /
        self.assertFalse(config.path_matches("server/tests/other.py", "server/tests/api_*"))
        self.assertTrue(config.path_matches(".crew/STOP", ".crew/STOP"))
        self.assertTrue(config.path_matches(".crew/stop", ".crew/STOP"))  # case-insensitive volume

    def test_is_protected(self):
        cfg = {"guard": {"protected": ["docs/private/"]}}
        self.assertTrue(config.is_protected(cfg, ".crew/crew.json"))
        self.assertTrue(config.is_protected(cfg, "docs/private/a.md"))
        self.assertTrue(config.is_protected({}, "x/eval/run.sh"))
        self.assertFalse(config.is_protected(cfg, "Sources/a.swift"))

    def test_is_protected_ignores_case(self):
        for rel in (".crew/CREW.json", ".Crew/crew.json", ".crew/Ledger.jsonl", ".Claude/settings.json",
                    "W/.GitHub/workflows/x.yml", "Crew-Kit/crew/guard.py"):
            self.assertTrue(config.is_protected({}, rel), rel)
        self.assertTrue(any(config.path_matches(".Claude/agents/x.md", p) for p in config.TIER_B))

    def test_rel_path_strips_worktree(self):
        p = self.proj
        wt = p + "/whisper-master/.claude/worktrees/feat-x/Sources/a.swift"
        self.assertEqual(config.rel_path(p, wt, p), ("whisper-master/Sources/a.swift", "feat-x"))
        self.assertEqual(config.rel_path(p, "Sources/a.swift", p), ("Sources/a.swift", None))
        self.assertEqual(config.rel_path(p, p + "/a/../b.txt", "/elsewhere"), ("b.txt", None))
        self.assertEqual(config.rel_path(p, "b.txt", p + "/sub"), ("sub/b.txt", None))
        self.assertEqual(config.rel_path(p, p + "/x/.claude/worktrees/w", p), ("x", "w"))

    def test_rel_path_root_inside_a_worktree(self):
        root = "/r/.claude/worktrees/w"
        self.assertEqual(config.rel_path(root, root + "/src/a.py", "/"), ("src/a.py", None))
        self.assertEqual(config.rel_path(root, "src/a.py", root), ("src/a.py", None))
        self.assertEqual(config.rel_path(root, root, "/"), (".", None))
        self.assertEqual(config.rel_path(root, "/r/src/a.py", "/"), (None, None))

    def test_rel_path_outside(self):
        self.assertEqual(config.rel_path(self.proj, "/etc/passwd", self.proj), (None, None))
        self.assertEqual(config.rel_path(self.proj, self.proj + "-other/a", self.proj), (None, None))
        self.assertEqual(config.rel_path(self.proj, "../x", self.proj), (None, None))

    def test_rel_path_expands_home(self):
        with mock.patch.dict(os.environ, {"HOME": self.proj}):
            self.assertEqual(config.rel_path(self.proj, "~/a.txt", "/")[0], "a.txt")

    def test_find_project(self):
        mk_project(self.proj)
        deep = os.path.join(self.proj, "a", "b")
        os.makedirs(deep)
        self.assertEqual(config.find_project(deep), self.proj)
        self.assertIsNone(config.find_project(self.tmp))

    def test_find_project_stops_at_home(self):
        mk_project(self.proj)
        sub = os.path.join(self.proj, "sub")
        os.makedirs(sub)
        with mock.patch.dict(os.environ, {"HOME": self.proj}):
            self.assertIsNone(config.find_project(sub))

    def test_stop_set(self):
        self.assertFalse(config.stop_set(self.proj))
        os.makedirs(os.path.join(self.proj, ".crew"))
        open(os.path.join(self.proj, ".crew", "STOP"), "w").close()
        self.assertTrue(config.stop_set(self.proj))
        os.remove(os.path.join(self.proj, ".crew", "STOP"))
        self.assertFalse(config.stop_set(None))
        os.makedirs(self.home)
        open(os.path.join(self.home, "STOP"), "w").close()
        self.assertTrue(config.stop_set(None))


class TestLedger(Base):
    def test_append_and_read(self):
        config.append_ledger(self.proj, {"t": "reserve", "run_id": "r1", "cap_usd": 2.0})
        config.append_ledger(self.proj, {"t": "run", "run_id": "r1", "cost_usd": 0.5})
        rows = config.read_ledger(self.proj)
        self.assertEqual([r["t"] for r in rows], ["reserve", "run"])
        self.assertEqual(rows[0]["v"], 1)
        self.assertRegex(rows[0]["ts"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$")
        self.assertTrue(os.path.exists(os.path.join(self.proj, ".crew", "ledger.lock")))

    def test_read_skips_bad_lines_and_tails(self):
        path = os.path.join(self.proj, ".crew", "ledger.jsonl")
        os.makedirs(os.path.dirname(path))
        with open(path, "w") as fh:
            fh.write('{"t":"run","n":1}\nnot json\n[1]\n\n{"t":"run","n":2}\n{"t":"run","n":3}\n')
        self.assertEqual([r["n"] for r in config.read_ledger(self.proj)], [1, 2, 3])
        tail = config.read_ledger(self.proj, tail_bytes=22)  # cuts into the middle of line n=2
        self.assertEqual([r["n"] for r in tail], [3])
        self.assertEqual(len(config.read_ledger(self.proj, tail_bytes=10000)), 3)
        self.assertEqual(config.read_ledger(self.tmp), [])
        # A cut exactly on a line boundary keeps the whole line.
        self.assertEqual([r["n"] for r in config.read_ledger(self.proj, tail_bytes=18)], [3])
        self.assertEqual([r["n"] for r in config.read_ledger(self.proj, tail_bytes=36)], [2, 3])

    def test_lock_is_exclusive(self):
        import fcntl
        with config.ledger_lock(self.proj):
            fd = os.open(os.path.join(self.proj, ".crew", "ledger.lock"), os.O_RDWR)
            try:
                with self.assertRaises(OSError):
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(fd)
        with config.ledger_lock(self.proj):
            pass

    def test_utc_ts(self):
        self.assertRegex(config.utc_ts(), r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$")


class TestSpent(unittest.TestCase):
    def test_open_reserve_counts_closed_does_not(self):
        rows = [
            {"t": "reserve", "run_id": "r1", "cap_usd": 2.0},
            {"t": "run", "run_id": "r1", "cost_usd": 0.5},
            {"t": "reserve", "run_id": "r2", "cap_usd": 1.5},
            {"t": "event", "kind": "stop.on"},
        ]
        self.assertAlmostEqual(config.spent(rows), 2.0)

    def test_filters(self):
        now = datetime.now(timezone.utc)
        today = now.astimezone().date().isoformat()
        old = (now - timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        new = now.strftime("%Y-%m-%dT%H:%M:%S.000Z")
        rows = [
            {"t": "run", "run_id": "a", "cost_usd": 1.0, "ts": old, "task_id": "t1", "loop_id": "l1"},
            {"t": "run", "run_id": "b", "cost_usd": 2.0, "ts": new, "task_id": "t1", "loop_id": None},
            {"t": "reserve", "run_id": "c", "cap_usd": 4.0, "ts": new, "task_id": "t2", "loop_id": "l1"},
            {"t": "run", "run_id": "d", "cost_usd": None, "ts": new},
        ]
        self.assertAlmostEqual(config.spent(rows, day=today), 6.0)
        self.assertAlmostEqual(config.spent(rows, task_id="t1"), 3.0)
        self.assertAlmostEqual(config.spent(rows, loop_id="l1"), 5.0)
        self.assertAlmostEqual(config.spent(rows, day=today, task_id="t1", loop_id="l1"), 0.0)


def _auto(level, set_at, expires=None):
    return {"autonomy": {"level": level, "set_at": set_at.isoformat(),
                         "expires_at": expires.isoformat() if expires else None}}


class TestEffectiveLevel(unittest.TestCase):
    now = datetime(2026, 11, 27, 12, 0, tzinfo=timezone(timedelta(hours=5, minutes=30)))
    set_at = now - timedelta(days=1)

    def demote(self, when):
        return {"t": "event", "kind": "demote", "ts": when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")}

    def test_plain_levels(self):
        for lv in ("L0", "L1", "L2", "L3"):
            self.assertEqual(config.effective_level(_auto(lv, self.set_at), [], self.now), lv)

    def test_l4_l5_need_a_valid_expiry(self):
        ok = self.now + timedelta(days=2)
        self.assertEqual(config.effective_level(_auto("L4", self.set_at, ok), [], self.now), "L4")
        self.assertEqual(config.effective_level(_auto("L5", self.set_at, ok), [], self.now), "L5")
        # missing
        self.assertEqual(config.effective_level(_auto("L4", self.set_at), [], self.now), "L3")
        self.assertEqual(config.effective_level(_auto("L5", self.set_at), [], self.now), "L3")
        # expired
        past = self.now - timedelta(minutes=1)
        self.assertEqual(config.effective_level(_auto("L4", self.set_at, past), [], self.now), "L3")

    def test_l4_30_day_limit_and_l5_7_day_limit(self):
        s = self.set_at
        self.assertEqual(config.effective_level(_auto("L4", s, s + timedelta(days=30)), [], self.now), "L4")
        self.assertEqual(config.effective_level(_auto("L4", s, s + timedelta(days=30, seconds=1)), [], self.now), "L3")
        self.assertEqual(config.effective_level(_auto("L5", s, s + timedelta(days=7)), [], self.now), "L5")
        self.assertEqual(config.effective_level(_auto("L5", s, s + timedelta(days=8)), [], self.now), "L3")

    def test_demotions_count_after_set_at(self):
        cfg = _auto("L3", self.set_at)
        rows = [self.demote(self.set_at - timedelta(hours=1)),
                self.demote(self.set_at + timedelta(hours=1))]
        self.assertEqual(config.effective_level(cfg, rows, self.now), "L2")
        rows.append({"t": "event", "kind": "breach", "ts": rows[1]["ts"]})
        self.assertEqual(config.effective_level(cfg, rows, self.now), "L2")

    def test_unreadable_demote_ts_counts(self):
        cfg = _auto("L3", self.set_at)
        rows = [{"t": "event", "kind": "demote", "ts": "garbage"}, {"t": "event", "kind": "demote"}]
        self.assertEqual(config.effective_level(cfg, rows, self.now), "L1")

    def test_demotion_applies_after_expiry_cap(self):
        cfg = _auto("L4", self.set_at)  # no expiry: L3, then one demote: L2
        self.assertEqual(config.effective_level(cfg, [self.demote(self.now - timedelta(hours=1))], self.now), "L2")

    def test_l0_floor(self):
        cfg = _auto("L1", self.set_at)
        rows = [self.demote(self.set_at + timedelta(minutes=i + 1)) for i in range(5)]
        self.assertEqual(config.effective_level(cfg, rows, self.now), "L0")

    def test_bad_level_is_l0(self):
        self.assertEqual(config.effective_level({"autonomy": {"level": "L9"}}, [], self.now), "L0")
        self.assertEqual(config.effective_level({}, [], self.now), "L0")

    def test_zulu_set_at(self):
        cfg = {"autonomy": {"level": "L3", "set_at": "2026-11-27T05:00:00Z"}}
        rows = [{"t": "event", "kind": "demote", "ts": "2026-11-27T06:00:00.000Z"}]
        self.assertEqual(config.effective_level(cfg, rows, self.now), "L2")


class TestSessions(Base):
    def test_round_trip_and_atomic(self):
        self.assertIsNone(config.read_session("s1"))
        self.assertIsNone(config.read_session(None))
        config.write_session("s1", {"v": 1, "agent": "nova"})
        self.assertEqual(config.read_session("s1")["agent"], "nova")
        self.assertEqual(config.session_file("s1"), os.path.join(self.home, "sessions", "s1.json"))
        self.assertEqual(os.listdir(os.path.join(self.home, "sessions")), ["s1.json"])

    def test_bad_ids(self):
        self.assertIsNone(config.read_session("../x"))
        with self.assertRaises(ValueError):
            config.write_session("../x", {})

    def test_crew_home(self):
        self.assertEqual(config.crew_home(), self.home)
        with mock.patch.dict(os.environ, {"CREW_HOME": self.home + "/"}):
            self.assertEqual(config.crew_home(), self.home)
        with mock.patch.dict(os.environ, {"CREW_HOME": ""}):
            self.assertEqual(config.crew_home(), os.path.expanduser("~/.crew"))

    def test_account(self):
        cfg = {"budget": {"account": None}}
        self.assertEqual(config.account(cfg), "default")
        with mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": "/Users/x/.claude-shob"}):
            self.assertEqual(config.account(cfg), "shob")
            with mock.patch.dict(os.environ, {"CREW_ACCOUNT": "env"}):
                self.assertEqual(config.account(cfg), "env")
                self.assertEqual(config.account({"budget": {"account": "cfg"}}), "cfg")
        with mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": "/Users/x/.claude"}):
            self.assertEqual(config.account(cfg), "claude")


class TestResolve(Base):
    def setUp(self):
        super().setUp()
        mk_project(self.proj)
        self.cfg, _ = config.load(self.proj)

    def test_project_rules(self):
        deep = os.path.join(self.proj, "a")
        os.makedirs(deep)
        hook = {"session_id": "s1", "cwd": deep}
        self.assertEqual(config.resolve_project(hook, {}), self.proj)  # rule 3
        other = os.path.join(self.tmp, "other")
        mk_project(other)
        config.write_session("s1", {"project": other})
        self.assertEqual(config.resolve_project(hook, {}), other)  # rule 2 beats 3
        self.assertEqual(config.resolve_project(hook, {"CREW_PROJECT": self.proj}), self.proj)  # rule 1
        self.assertEqual(config.resolve_project(hook, {"CREW_PROJECT": self.tmp}), other)  # no crew.json there
        self.assertIsNone(config.resolve_project({"cwd": self.tmp}, {}))
        self.assertIsNone(config.resolve_project({}, {}))

    def test_agent_rule_1_agent_type(self):
        self.assertEqual(config.resolve_agent({"agent_type": "qa", "agent_id": "x"}, self.cfg, {}), ("qa", False))
        self.assertEqual(config.resolve_agent({"agent_type": "nova"}, self.cfg, {}), ("nova", False))

    def test_agent_rule_2_session_map(self):
        config.write_session("s1", {"agent": "nova"})
        # main session, no agent_type
        self.assertEqual(config.resolve_agent({"session_id": "s1"}, self.cfg, {}), ("nova", False))
        # built-in subagent in a mapped session
        hook = {"session_id": "s1", "agent_type": "general-purpose", "agent_id": "a1"}
        self.assertEqual(config.resolve_agent(hook, self.cfg, {}), ("nova", True))
        # a crew agent still wins over the map
        hook = {"session_id": "s1", "agent_type": "c-web", "agent_id": "a1"}
        self.assertEqual(config.resolve_agent(hook, self.cfg, {}), ("c-web", False))

    def test_agent_rule_3_env(self):
        self.assertEqual(config.resolve_agent({"session_id": "none"}, self.cfg, {"CREW_AGENT": "pm"}), ("pm", False))
        self.assertEqual(config.resolve_agent({}, self.cfg, {"CREW_AGENT": "ghost"}), (None, False))

    def test_agent_rule_4_none(self):
        self.assertEqual(config.resolve_agent({"session_id": "none", "agent_type": "Explore"}, self.cfg, {}),
                         (None, False))
        self.assertEqual(config.resolve_agent({}, {}, {}), (None, False))

    def test_agent_lookup(self):
        self.assertEqual(config.agent(self.cfg, "qa")["name"], "Quinn")
        self.assertIsNone(config.agent(self.cfg, "zz"))


if __name__ == "__main__":
    unittest.main()
