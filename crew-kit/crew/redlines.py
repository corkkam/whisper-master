"""Red lines (spec section 10.2) and the tool allowlist (section 14.3 step 5).

This file is protected. Only the owner changes it.
"""
from __future__ import annotations

import re

# Every pattern is matched with re.IGNORECASE: the owner's volume ignores case, so "GIT" runs git.
_I = re.IGNORECASE
# a VAR=value word
_VAR = r"[A-Za-z_][A-Za-z0-9_]*=\S*\s+"
# wrapper words that run the next word: "env claude", "/usr/bin/env claude", "xargs crew".
_WRAP = r"(?:(?:[^\s=]*/)?(?:env|exec|command|builtin|time|nice|nohup|xargs|sudo|npx|bunx)\s+(?:-\S+\s+)*(?:" + _VAR + r")*)*"
# a shell that runs a string: "bash -c 'crew autonomy L5'", "sh -lc \"claude -p hi\"".
_SHELL = r"(?:(?:[^\s=]*/)?(?:sh|bash|zsh|dash|ksh)\s+(?:-\S+\s+)*['\"]?\s*(?:" + _VAR + r")*" + _WRAP + r")?"
# command position: line start, after a separator or a subshell opener, after optional VAR=value words,
# wrapper words and one "sh -c" string. It keeps words inside commit messages from matching.
CMD = r"(?:^|[;&|(\n]|\$\(|`)\s*(?:" + _VAR + r")*" + _WRAP + _SHELL
# git and gh with global options before the subcommand ("git -C . reset", "gh -R a/b pr merge").
# The alternatives are disjoint, so a run of "-C" tokens cannot backtrack exponentially.
GIT = (r"\bgit\b(?:\s+(?:-C\s+(?:\"[^\"]*\"|'[^']*'|(?![\"'-])\S+)"
       r"|--(?:git-dir|work-tree|namespace|exec-path|super-prefix|config-env)\s+(?![\"'-])\S+"
       r"|-[\w-]+(?:=\S+)?))*\s+")
GH = r"\bgh\b(?:\s+-[\w-]+(?:=\S+|\s+(?![\"'-])\S+)?)*\s+"
# a crew binary: the shim, a path, or "python3 -m crew.cli".
CREW = r"(?:(?:[^\s=]*/)?crew|(?:[^\s=]*/)?python[\d.]*\s+(?:-\S+\s+)*-m\s+crew(?:\.cli)?)\s+"
# hosts that send messages to people or change remote state (also checked on WebFetch URLs)
HOSTS = [r"api\.github\.com", r"api\.linear\.app", r"api\.telegram\.org", r"hooks\.slack\.com",
         r"discord(?:app)?\.com/api/webhooks"]
# The two allowlists below stay case-sensitive: a narrow allowlist is the safe side ("-c" is not "-C").
# the only allowed push form
PUSH_OK = r"^\s*git(\s+-C\s+\S+)?\s+push(\s+(-u|--set-upstream))?\s+origin\s+(HEAD:)?((feature|fix)/[\w.-]+(/[\w.-]+)*|crew/improve-[\w.-]+)\s*$"
# the workspace gh form (AGENTS.md section 6 item 2); checked first, then tested with the GH_TOKEN=$(...) prefix removed
GH_OK = r"^\s*GH_TOKEN=\$\(gh auth token -u [\w-]+\)\s+gh\s+(pr\s+(create|view|list|checks|diff|status|edit)|run\s+(list|view)|repo\s+view)\b[^;&|`]*$"

_GH_PREFIX = re.compile(r"^\s*GH_TOKEN=\$\(gh auth token -u [\w-]+\)\s+")
# any git global options may come before "push"; every form with an extra option then fails PUSH_OK.
_PUSH = re.compile(GIT + r"push\b", _I)
# one simple command: no separator after the match
_SEG = r"[^;&|\n]*"

# The table of section 10.2, in table order, with the global-option and case fixes of the review.
PATTERNS = [
    # Merge, release, tags, CI
    GH + r"pr\s+merge\b",
    GH + r"release\b",
    GIT + r"tag\b",
    GH + r"workflow\s+run\b",
    GH + r"run\s+(rerun|cancel)\b",
    # GitHub API and tokens
    GH + r"api\b.*(\s-[fFX]|\s--(field|raw-field|method|input)\b)",
    GH + r"auth\s+(token|login|logout|switch|refresh)\b",
    GH + r"(issue|pr)\s+(comment|close|reopen|review)\b",
    GH + r"(repo|secret|variable|ruleset)\s+(create|delete|edit|set|rename|archive)\b",
    # Version bump or release script
    r"Scripts/(release|bump|publish)",
    r"\bagvtool\b",
    # Deploy, secrets, R2, tickets
    r"\bpnpm\s+(run\s+)?cf:deploy\b",
    r"\bwrangler\b.*\b(deploy|publish|secret|r2|kv|d1)\b",
    CMD + r"cf\s+(deploy|workers|r2|secret|kv|d1)\b",
    r"\b(aws\s+s3|rclone|s3cmd)\b",
    r"\b(npm|pnpm|yarn)\s+publish\b",
    r"\bsecurity\s+(find|dump|export)-",
    # Messages to people (and the GitHub and Linear API hosts)
] + HOSTS + [
    r"\bsendmail\b",
    r"\bmail\s+-s\b",
    r"\bosascript\b.*\b(Messages|Mail)\b",
    # Deletes of work, in every flag spelling. "-D" stays case-sensitive: "git branch -d" is allowed.
    GIT + r"branch\b" + _SEG + r"\s(?-i:-\w*D)",
    GIT + r"branch\b(?=" + _SEG + r"\s(?:-\w*d|--delete\b))" + _SEG + r"\s(?:-\w*f|--force\b)",
    GIT + r"worktree\s+remove\b",
    GIT + r"reset\b" + _SEG + r"\s--hard\b",
    GIT + r"clean\b" + _SEG + r"\s(?:-\w*f|--force\b)",
    GIT + r"stash\s+(drop|clear)\b",
    r"\brm\b(?=" + _SEG + r"\s(?:-\w*r|--recursive\b))" + _SEG + r"\s(?:-\w*f|--force\b)",
    r"\bfind\b" + _SEG + r"\s-delete\b",
    # Nested runs and scheduling. "autonomy" is added by build-notes (only a person raises the level).
    CMD + r"(?:[^\s=]*/)?(claude|codex)\b",
    r"@anthropic-ai/claude-code\b",
    CMD + CREW + r"(run|loop|resume|init|install|add-component|add-persona|autonomy|statusline)\b",
    # a probe starts a nested claude -p call
    CMD + CREW + r"budget\b" + _SEG + r"--probe\b",
    r"--approved\b",
    CMD + r"(nohup|setsid|launchctl|crontab|at|batch|disown|screen|tmux)\b",
    r"(?<![&>|])&\s*$",
    # Crew control. "crew stop --clear" is added by build-notes.
    r"\.crew/STOP",
    r"--dangerously",
    r"bypassPermissions",
    CMD + CREW + r"stop\b" + _SEG + r"--clear\b",
]

_COMPILED = [re.compile(p, _I) for p in PATTERNS]

ALLOWED_TOOLS = frozenset([
    "Read", "Grep", "Glob", "LS", "NotebookRead", "Edit", "Write", "MultiEdit", "NotebookEdit",
    "Bash", "TodoWrite", "WebSearch", "WebFetch", "Agent", "Task", "Skill", "ToolSearch",
    "AskUserQuestion",
])


def check(command: str, extra: list) -> bool:
    """Return True when a red line matches the command. A bad extra regex raises re.error."""
    cmd = command or ""
    if re.search(GH_OK, cmd):
        cmd = _GH_PREFIX.sub("", cmd, count=1)
    if _PUSH.search(cmd) and not re.search(PUSH_OK, cmd):
        return True
    if any(rx.search(cmd) for rx in _COMPILED):
        return True
    return any(re.search(p, cmd, _I) for p in (extra or []))
