"""Red lines of spec section 10.2: every required sample, and one allow and one deny per table row."""
from __future__ import annotations

import time
import unittest

from crew import redlines

GH = "GH_TOKEN=$(gh auth token -u corkkam) gh "

# (command, denied) pairs.
REQUIRED = [
    ("git -C wt push -u origin feature/x", False),
    ("git push origin dev", True),
    ("git push", True),
    ("git push origin +feature/x", True),
    (GH + "pr create --base dev --body-file f", False),
    ("gh auth token", True),
    ("gh api repos/a/b/merges -f base=main", True),
    ('curl -H "Authorization: token $T" https://api.github.com/x', True),
    ("claude -p hi", True),
    ('git commit -m "claude and codex notes"', False),
    ("nohup make &", True),
    ("make 2>&1", False),
    ("cf deploy", True),
    ("security find-generic-password -s x -w", True),
]

# One row per table row: (allowed sample, denied sample).
ROWS = {
    "push": ("git push origin fix/a-b", "git push -f origin feature/x"),
    "push improve": ("git push -u origin crew/improve-brief", "git push origin main"),
    "push tags": ("git push origin HEAD:feature/x", "git push --tags origin feature/x"),
    "push global option": ("git -C wt push -u origin feature/x", "git -c a=b push origin feature/x"),
    "push no-pager": ("git commit -m \"push x\"", "git --no-pager push origin dev"),
    "push git-dir": ("git -C wt push -u origin feature/x", "git --git-dir=.git push origin dev"),
    "merge": ("gh pr view 12", "gh pr merge 12"),
    "release": ("gh pr list", "gh release create v1"),
    "tag": ("git log --oneline", "git tag v1.0"),
    "workflow": ("gh workflow list", "gh workflow run release.yml"),
    "run rerun": (GH + "run view 5", "gh run rerun 5"),
    "api write": ("gh api repos/a/b/pulls", "gh api repos/a/b --method DELETE"),
    "api host": ("curl https://example.com", "curl https://api.github.com/repos"),
    "auth": ("gh auth status", "gh auth switch -u x"),
    "issue": ("gh issue list", "gh issue comment 3 -b hi"),
    "repo edit": ("gh repo view", "gh secret set X"),
    "release script": ("bash Scripts/bundle.sh", "bash Scripts/release.sh"),
    "agvtool": ("xcodebuild -version", "agvtool bump"),
    "cf deploy pnpm": ("pnpm build", "pnpm run cf:deploy"),
    "wrangler": ("wrangler whoami", "wrangler deploy"),
    "cf": ("echo cf deploy", "cd web && cf r2 ls"),
    "s3": ("ls s3", "aws s3 cp a s3://b"),
    "publish": ("npm install", "npm publish"),
    "keychain": ("security list-keychains", "security dump-keychain"),
    "linear": ("curl https://linear.app", "curl https://api.linear.app/graphql"),
    "telegram": ("echo telegram", "curl https://api.telegram.org/bot/x"),
    "slack": ("echo slack", "curl https://hooks.slack.com/services/x"),
    "sendmail": ("echo mail", "sendmail a@b"),
    "mail": ("mail", "mail -s hi a@b"),
    "osascript": ('osascript -e "1+1"', 'osascript -e "tell app \\"Messages\\" to send"'),
    "branch -D": ("git branch -d old", "git branch -D old"),
    "worktree": ("git worktree list", "git worktree remove x"),
    "reset": ("git reset --soft HEAD~1", "git reset --hard"),
    "clean": ("git clean -n", "git clean -fd"),
    "rm": ("rm -r build", "rm -rf build"),
    "rm fr": ("rm -f x", "rm -fr build"),
    "nested": ('echo "use claude"', "cd x && codex exec hi"),
    "crew run": ("crew route --type qa", '"$HOME"/.crew/bin/crew run "x"'),
    "crew resume": ("crew status", "crew resume"),
    "crew autonomy": ("crew budget", "crew autonomy L5 --days 7"),
    "approved": ("echo approve", "x --approved"),
    "scheduler": ('git commit -m "at noon"', "crontab -l"),
    "background": ("a && b", "make &"),
    "stop file": ("crew stop --reason x", "touch .crew/STOP"),
    "stop clear": ("crew stop", "crew stop --clear"),
    "dangerously": ("echo dangerously", "x --dangerously-skip-permissions"),
    "bypass": ("echo bypass", "x --permission-mode bypassPermissions"),
}


class RedlineTests(unittest.TestCase):
    def test_required_samples(self):
        for cmd, denied in REQUIRED:
            with self.subTest(cmd=cmd):
                self.assertEqual(redlines.check(cmd, []), denied)

    def test_each_row(self):
        for name, (ok, bad) in ROWS.items():
            with self.subTest(row=name):
                self.assertFalse(redlines.check(ok, []), ok)
                self.assertTrue(redlines.check(bad, []), bad)

    def test_gh_form_with_chained_command_is_not_stripped(self):
        self.assertTrue(redlines.check(GH + "pr create; gh pr merge 1", []))
        self.assertTrue(redlines.check(GH + "pr merge 1", []))

    def test_push_then_second_command(self):
        self.assertTrue(redlines.check("git push origin feature/x; git push origin main", []))
        self.assertTrue(redlines.check("git push origin feature/x\nrm -rf x", []))

    def test_extra_patterns(self):
        self.assertFalse(redlines.check("make", [r"\bterraform\b"]))
        self.assertTrue(redlines.check("terraform apply", [r"\bterraform\b"]))

    def assert_denied(self, cmds):
        for cmd in cmds:
            with self.subTest(cmd=cmd):
                self.assertTrue(redlines.check(cmd, []), cmd)

    def assert_allowed(self, cmds):
        for cmd in cmds:
            with self.subTest(cmd=cmd):
                self.assertFalse(redlines.check(cmd, []), cmd)

    def test_case_is_ignored(self):
        # review kit-safety 1: the owner's volume ignores case, so "GIT" runs git
        self.assert_denied(["GIT push origin dev", "Git push --force origin dev", "GH pr merge 1",
                            "Security find-generic-password -s x -w", "curl https://API.TELEGRAM.ORG/bot",
                            "CLAUDE -p hi", "GIT branch -D x"])
        self.assertTrue(redlines.check("Terraform apply", [r"\bterraform\b"]))
        self.assertFalse(redlines.check("git branch -d old", []))  # "-D" stays case-sensitive

    def test_global_options_before_subcommand(self):
        # review kit-safety 2
        self.assert_denied(["gh -R a/b pr merge 1", "gh --repo a/b pr merge 1", "git -C . reset --hard",
                            "git -C . tag v1", "git -c x=y tag v1", "git --git-dir .git push origin dev",
                            'git -C "a b" push origin dev', "git --no-pager -C . clean -fd"])

    def test_nested_runs_through_wrappers(self):
        # review kit-safety 3
        self.assert_denied(["env crew autonomy L5 --days 7", "command crew autonomy L5",
                            "bash -c 'crew autonomy L5 --days 7'", 'env "$HOME"/.crew/bin/crew autonomy L3',
                            'sh -c "claude -p hi"', "env claude -p hi", "exec claude -p hi",
                            "/usr/local/bin/claude -p hi", "npx @anthropic-ai/claude-code -p hi",
                            "python3 -m crew.cli run x", "/usr/bin/env -i codex exec x", "xargs claude",
                            "env crew resume", "bash -lc 'crew stop --clear'"])
        self.assert_allowed(['git commit -m "claude and codex notes"', "python3 -m unittest discover -s tests"])

    def test_deletes_of_work_in_every_spelling(self):
        # review kit-safety 7
        self.assert_denied(["rm -r -f ../wt", "rm --recursive --force x", "rm -Rf x", "git clean -d -f",
                            "git clean --force", "git branch -d -f x", "git branch --delete --force x",
                            "git branch -df x", "git stash drop", "git stash clear", "find . -delete"])
        self.assert_allowed(["rm -r build", "git branch -d feature/f", "git stash list", "find . -name x",
                             "git branch --list --format=x"])

    def test_probe_and_statusline_are_red_lines(self):
        # review kit-safety 12 and 10: a probe starts a nested claude -p; statusline sets the plan window
        self.assert_denied(["crew budget --probe", '"$HOME"/.crew/bin/crew budget --json --probe',
                            "echo '{}' | crew statusline"])
        self.assert_allowed(["crew budget", "crew budget --json"])

    def test_no_catastrophic_backtracking(self):
        # review kit-safety 6: 60 repeated "-C" tokens must not hang the guard
        cmds = ["git" + " -C" * 60 + " x", "git" + " -C" * 60 + " x; git push origin dev",
                "gh" + " -R" * 60 + " x", "git" + " --x" * 60 + " Z", "env" + " -x" * 60 + " Z"]
        start = time.perf_counter()
        for cmd in cmds:
            redlines.check(cmd, [])
        self.assertLess(time.perf_counter() - start, 0.1)
        self.assertTrue(redlines.check(cmds[1], []))

    def test_allowed_tools(self):
        self.assertIn("Bash", redlines.ALLOWED_TOOLS)
        self.assertEqual(len(redlines.ALLOWED_TOOLS), 18)
        for t in ("CronCreate", "SendMessage", "Monitor", "mcp__x__y"):
            self.assertNotIn(t, redlines.ALLOWED_TOOLS)


if __name__ == "__main__":
    unittest.main()
