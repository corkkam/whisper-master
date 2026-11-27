from __future__ import annotations

import inspect
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

from crew import config, events

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(os.path.dirname(HERE), "spec", "events-golden.jsonl")

# A literal copy of spec section 12.5. The app test embeds the same 10 lines.
GOLDEN_LINES = """\
{"v":1,"ts":"2026-11-27T14:00:00.000Z","src":"crew","event":"run.start","session":"s1","agent":"juno","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:01.000Z","src":"claude","event":"session.start","session":"s1","agent":"juno","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:05.000Z","src":"crew","event":"huddle.start","session":"s1","agent":"juno","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":["pm","c-input"]}
{"v":1,"ts":"2026-11-27T14:00:06.000Z","src":"claude","event":"agent.start","session":"s1","agent":"pm","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:20.000Z","src":"claude","event":"agent.stop","session":"s1","agent":"pm","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:30.000Z","src":"crew","event":"huddle.end","session":"s1","agent":"juno","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":["pm","c-input"]}
{"v":1,"ts":"2026-11-27T14:00:31.000Z","src":"claude","event":"agent.start","session":"s1","agent":"qa","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:40.000Z","src":"claude","event":"agent.stop","session":"s1","agent":"qa","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:41.000Z","src":"claude","event":"agent.start","session":"s1","agent":"c-input","project":"/tmp/crew-golden","tool":null,"kind":null,"note":null,"agents":[]}
{"v":1,"ts":"2026-11-27T14:00:42.000Z","src":"claude","event":"tool.start","session":"s1","agent":"c-input","project":"/tmp/crew-golden","tool":"Bash","kind":"test","note":null,"agents":[]}
"""

KEYS = ["v", "ts", "src", "event", "session", "agent", "project", "tool", "kind", "note", "agents"]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        p = mock.patch.dict(os.environ, {"CREW_HOME": self.tmp})
        p.start()
        self.addCleanup(p.stop)
        self.path = os.path.join(self.tmp, "events.jsonl")

    def rows(self, path=None):
        with open(path or self.path) as fh:
            return [json.loads(x) for x in fh.read().splitlines()]


class TestApi(unittest.TestCase):
    def test_names_and_signatures(self):
        self.assertIsInstance(events.EVENTS, frozenset)
        self.assertIsInstance(events.NOTES, frozenset)
        self.assertIsInstance(events.KINDS, frozenset)
        self.assertEqual(events.KINDS, {"test", "build", "git", "search", "edit", "read", "web", "agent", "other"})
        self.assertNotIn(None, events.NOTES)
        self.assertEqual(len(events.EVENTS), 23)
        self.assertEqual(len(events.NOTES), 33)
        sig = inspect.signature(events.kind_for)
        self.assertEqual([(p.name, p.kind.name, p.default) for p in sig.parameters.values()],
                         [("tool_name", "POSITIONAL_OR_KEYWORD", inspect._empty),
                          ("command", "POSITIONAL_OR_KEYWORD", None)])
        sig = inspect.signature(events.write_event)
        got = [(p.name, p.kind.name, p.default) for p in sig.parameters.values()]
        E = inspect._empty
        self.assertEqual(got, [
            ("project", "POSITIONAL_OR_KEYWORD", E), ("event", "POSITIONAL_OR_KEYWORD", E),
            ("agent", "POSITIONAL_OR_KEYWORD", E), ("src", "KEYWORD_ONLY", "crew"),
            ("session", "KEYWORD_ONLY", None), ("tool", "KEYWORD_ONLY", None),
            ("kind", "KEYWORD_ONLY", None), ("note", "KEYWORD_ONLY", None),
            ("agents", "KEYWORD_ONLY", ())])

    def test_every_note_in_spec_is_listed(self):
        for n in ("ok", "denied: protected path", "denied: public text", "backlog empty", "probe", "round 2"):
            self.assertIn(n, events.NOTES)


class TestKindFor(unittest.TestCase):
    def test_tool_names(self):
        k = events.kind_for
        for t in ("Read", "NotebookRead"):
            self.assertEqual(k(t), "read")
        for t in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
            self.assertEqual(k(t), "edit")
        for t in ("Grep", "Glob", "LS"):
            self.assertEqual(k(t), "search")
        for t in ("WebFetch", "WebSearch"):
            self.assertEqual(k(t), "web")
        for t in ("Agent", "Task"):
            self.assertEqual(k(t), "agent")
        self.assertEqual(k("mcp__claude_ai_Drive__read_file", "swift test"), "other")
        self.assertEqual(k("TodoWrite"), "other")
        self.assertEqual(k("Bash"), "other")

    def test_bash_test(self):
        for c in ("swift test", "swift test --filter AudioReplayTests", "xcodebuild test -scheme X",
                  "pytest -q", "python3 -m unittest discover", "/usr/bin/python3 -m pytest",
                  "npm test", "pnpm run test", "yarn test", "go test ./...", "cargo test",
                  "cd app && swift build && swift test", "FOO=1 pytest"):
            self.assertEqual(events.kind_for("Bash", c), "test", c)

    def test_bash_build(self):
        for c in ("swift build", "xcodebuild -scheme X", "pnpm build", "npm run build", "yarn build",
                  "make", "make all", "cargo build", "go build ./...", "cd x && make -j4"):
            self.assertEqual(events.kind_for("Bash", c), "build", c)

    def test_bash_git(self):
        for c in ("git status", "git -C wt push -u origin feature/x", "gh pr list",
                  "GH_TOKEN=abc gh pr create", "GH_TOKEN=$(gh auth token -u corkkam) gh pr view 3"):
            self.assertEqual(events.kind_for("Bash", c), "git", c)

    def test_bash_search(self):
        for c in ("grep -rn foo .", "rg foo", "ugrep x", "find . -name x", "ls -la", "fd name"):
            self.assertEqual(events.kind_for("Bash", c), "search", c)

    def test_bash_other(self):
        for c in ("echo hi", "bash eval/run.sh", "git_not_really", "lsof -i", "cat file"):
            self.assertEqual(events.kind_for("Bash", c), "other", c)

    def test_words_inside_a_message_do_not_match(self):
        self.assertEqual(events.kind_for("Bash", 'git commit -m "make swift test pass"'), "git")
        self.assertEqual(events.kind_for("Bash", 'echo "run pytest later"'), "other")


class TestWriteEvent(Base):
    def test_line_has_every_key_in_order(self):
        events.write_event("/p", "tool.start", "c-input", src="claude", session="s1", tool="Bash",
                           kind="test", note=None, agents=[])
        with open(self.path) as fh:
            raw = fh.read()
        self.assertTrue(raw.endswith("\n"))
        row = json.loads(raw)
        self.assertEqual(list(row), KEYS)
        self.assertEqual(row["v"], 1)
        self.assertRegex(row["ts"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$")
        self.assertEqual((row["src"], row["event"], row["session"], row["agent"], row["project"]),
                         ("claude", "tool.start", "s1", "c-input", "/p"))
        self.assertEqual((row["tool"], row["kind"], row["note"], row["agents"]), ("Bash", "test", None, []))

    def test_defaults(self):
        events.write_event("/p", "run.start", "nova")
        row = self.rows()[0]
        self.assertEqual((row["src"], row["session"], row["tool"], row["kind"], row["note"], row["agents"]),
                         ("crew", None, None, None, None, []))

    def test_bad_note_becomes_null_good_note_stays(self):
        events.write_event("/p", "guard.deny", "qa", note="denied: tool")
        events.write_event("/p", "guard.deny", "qa", note="because I said so")
        events.write_event("/p", "run.end", "nova", note="needs approval")
        notes = [r["note"] for r in self.rows()]
        self.assertEqual(notes, ["denied: tool", None, "needs approval"])

    def test_bad_kind_src_and_event(self):
        events.write_event("/p", "tool.end", "qa", src="evil", kind="weird")
        events.write_event("/p", "not.an.event", "qa")
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["src"], rows[0]["kind"]), ("crew", None))

    def test_agents_and_line_limit(self):
        events.write_event("/p", "huddle.start", "nova", agents=["pm", "c-input"])
        self.assertEqual(self.rows()[0]["agents"], ["pm", "c-input"])
        events.write_event("/p", "huddle.start", "nova", agents=["agent-%03d" % i for i in range(300)])
        with open(self.path, "rb") as fh:
            last = fh.read().splitlines()[-1]
        self.assertLessEqual(len(last) + 1, 1024)
        self.assertEqual(list(json.loads(last)), KEYS)

    def test_a_line_that_cannot_fit_is_not_written(self):
        events.write_event("/p", "huddle.start", "nova", agents=["pm"])
        before = os.path.getsize(self.path)
        events.write_event("/p" + "x" * 1100, "huddle.start", "nova", agents=["pm"])
        self.assertEqual(os.path.getsize(self.path), before)

    def test_no_input_text_is_written(self):
        secret = "SECRETWORD-hunter2"
        cmd = "echo " + secret
        kind = events.kind_for("Bash", cmd)
        events.write_event("/p", "tool.start", "qa", tool="Bash", kind=kind)
        with open(self.path) as fh:
            self.assertNotIn(secret, fh.read())

    def test_rotation(self):
        with mock.patch.object(events, "ROTATE_BYTES", 1000):
            for i in range(12):
                events.write_event("/p", "prompt", "nova", session="s%d" % i)
        self.assertTrue(os.path.exists(self.path + ".1"))
        self.assertLess(os.path.getsize(self.path), 1000 + 300)
        self.assertGreater(len(self.rows(self.path + ".1")), 0)
        total = len(self.rows()) + len(self.rows(self.path + ".1"))
        self.assertEqual(total, 12)  # one rotation only, nothing dropped here

    def test_rotation_constant_is_8_mib(self):
        self.assertEqual(events.ROTATE_BYTES, 8 * 1024 * 1024)

    def test_never_raises(self):
        blocker = os.path.join(self.tmp, "file")
        open(blocker, "w").close()
        with mock.patch.dict(os.environ, {"CREW_HOME": os.path.join(blocker, "sub")}):
            events.write_event("/p", "prompt", "nova")  # parent is a file
        events.write_event(None, "prompt", object(), agents=None)
        events.write_event("/p", None, "nova")


class TestGolden(unittest.TestCase):
    def test_file_equals_literal(self):
        with open(GOLDEN, "rb") as fh:
            data = fh.read()
        self.assertEqual(data.decode("utf-8"), GOLDEN_LINES)
        self.assertEqual(data.count(b"\n"), 10)
        self.assertTrue(data.endswith(b"\n"))

    def test_lines_match_the_writer_shape(self):
        for line in GOLDEN_LINES.splitlines():
            row = json.loads(line)
            self.assertEqual(list(row), KEYS)
            self.assertIn(row["event"], events.EVENTS)
            self.assertEqual(row["project"], "/tmp/crew-golden")
            self.assertEqual(json.dumps(row, separators=(",", ":")), line)


if __name__ == "__main__":
    unittest.main()
