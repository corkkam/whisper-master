#!/bin/bash
# Crew smoke run with a real model (WP8). It uses the plan of the signed-in account.
# Each model run is capped at 0.20 USD. The budget probe is capped at 0.02 USD.
#
# Usage: bash crew-kit/tests/smoke.sh [all|root|temp|probe]    (default: all, in that order)
#   root   crew budget --probe and one crew run in the workspace root (it needs a crew from crew init)
#   temp   a temp git repo with its own crew: the lead creates and commits one file on a feature branch
#   probe  one plain claude -p call that measures onFailure "block", UserPromptSubmit additionalContext
#          and hook environment inheritance
# The script stops at the first failure. It keeps its files in the folder that it prints first.
#
# Environment: CREW_SMOKE_ROOT (default: the folder that holds the app repo), CREW_SMOKE_CLAUDE
# (default: claude on PATH), CREW_SMOKE_PYTHON (required: the interpreter for the shim).
# The script runs "crew install --force" from this checkout. That replaces the live ~/.crew/kit that the
# hooks of every session use, and it fixes the shim interpreter. Use a fast python3: the guard median
# was 38 ms on pyenv 3.11 and 108 ms on /usr/bin/python3 3.9 (target: under 100 ms).
set -euo pipefail

STEP="${1:-all}"
case "$STEP" in all|root|temp|probe) ;; *) echo "usage: smoke.sh [all|root|temp|probe]" >&2; exit 2 ;; esac
KIT="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${CREW_SMOKE_PYTHON:-}" ] || { echo "smoke: set CREW_SMOKE_PYTHON to a fast python3. The script replaces the installed kit ~/.crew/kit and its shim." >&2; exit 2; }
PY="$CREW_SMOKE_PYTHON"
ROOT="${CREW_SMOKE_ROOT:-$(cd "$(git -C "$KIT" rev-parse --path-format=absolute --git-common-dir)/../.." && pwd)}"
REAL_CLAUDE="${CREW_SMOKE_CLAUDE:-$(command -v claude || true)}"
C="$HOME/.crew/bin/crew"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/crew-smoke.XXXXXX")"

say() { echo "smoke: $*"; }
fail() { echo "smoke: FAIL: $*" >&2; exit 1; }

[ -n "$REAL_CLAUDE" ] || fail "claude is not on PATH"
# A parent Claude Code session sets these. They override agent models and confuse the child (build notes 9).
for v in $(env | sed -n 's/^\(CLAUDE_CODE_[A-Za-z0-9_]*\)=.*/\1/p'); do
  [ "$v" = CLAUDE_CODE_OAUTH_TOKEN ] || unset "$v"
done
unset CLAUDECODE CLAUDE_PID CLAUDE_EFFORT CREW_HOME CREW_AGENT CREW_PROJECT CREW_RUN_ID CREW_TASK_ID CREW_AUTONOMOUS
export CREW_CLAUDE_BIN="$REAL_CLAUDE"
say "files in $OUT"

# A claude wrapper that keeps a copy of the stream and of stderr. crew run reads the same stream.
cat > "$OUT/claude-tee" <<EOF
#!/bin/bash
set -o pipefail
log="\${CREW_SMOKE_LOG:-$OUT/stream}"
"$REAL_CLAUDE" "\$@" 2> >(trap '' INT TERM; exec tee -a "\$log.err" >&2) | (trap '' INT TERM; exec tee -a "\$log.jsonl")
EOF
chmod +x "$OUT/claude-tee"

# The checks, in Python: the last run row, its events, the hook events of its session, and the probe.
cat > "$OUT/check.py" <<'EOF'
import json, os, sys

def lines(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return [json.loads(x) for x in fh if x.strip()]
    except OSError:
        return []

def stream_facts(prefix):
    stream = lines(prefix + ".jsonl")
    init = next((o for o in stream if o.get("type") == "system" and o.get("subtype") == "init"), None)
    err = open(prefix + ".err", encoding="utf-8", errors="replace").read() if os.path.exists(prefix + ".err") else ""
    print("smoke: init line keys: %s" % (sorted(init) if init else "none"))
    print("smoke: init permissionMode: %s" % ((init or {}).get("permissionMode")))
    echo = [k for k in (init or {}) if "auto" in k.lower() or "setting" in k.lower()]
    print("smoke: init keys about settings: %s" % (echo or "none"))
    bad = [x for x in err.splitlines() if "setting" in x.lower() or "autocontinue" in x.lower()]
    print("smoke: stderr lines about settings: %s" % (bad or "none"))

def check_run(project, max_cost, prefix):
    cfg = json.load(open(os.path.join(project, ".crew", "crew.json"), encoding="utf-8"))
    lead = cfg["lead"]
    rows = lines(os.path.join(project, ".crew", "ledger.jsonl"))
    runs = [r for r in rows if r.get("t") == "run" and r.get("purpose") != "probe"]
    if not runs:
        sys.exit("no run row")
    row = runs[-1]
    print("smoke: run row: " + json.dumps({k: row.get(k) for k in (
        "run_id", "agent", "model", "outcome", "subtype", "crew_result", "cost_usd", "cap_usd", "num_turns",
        "duration_ms", "hash_changes", "win_before", "win_after", "exit_code")}))
    home = os.path.expanduser("~/.crew")
    evs = [e for e in lines(os.path.join(home, "events.jsonl")) if e.get("session") == row["session_id"]]
    names = [e["event"] for e in evs]
    hook_evs = sorted(set(e["event"] for e in evs if e.get("src") == "claude"))
    print("smoke: events of the session: %d, hook events: %s" % (len(evs), hook_evs or "none"))
    denies = [e["note"] for e in evs if e["event"] == "guard.deny"]
    print("smoke: guard denies: %s" % (denies or "none"))
    stream_facts(prefix)
    problems = []
    if row["outcome"] != "ok":
        problems.append("outcome is %s" % row["outcome"])
    if float(row["cost_usd"] or 0) > max_cost:
        problems.append("cost %.4f is over %.2f" % (row["cost_usd"], max_cost))
    for want in ("run.start", "run.end"):
        if not any(e["event"] == want and e["agent"] == lead for e in evs):
            problems.append("no %s event for %s" % (want, lead))
    if problems:
        sys.exit("; ".join(problems))
    print("smoke: COST %s %.4f USD" % (os.path.basename(prefix), float(row["cost_usd"])))

def check_probe(out):
    stream = lines(os.path.join(out, "probe.jsonl"))
    result = next((o for o in stream if o.get("type") == "result"), None)
    if result is None:
        sys.exit("the probe run has no result line")
    tool_results, bash_uses = [], 0
    for o in stream:
        content = (o.get("message") or {}).get("content") if o.get("type") in ("user", "assistant") else None
        for blk in content if isinstance(content, list) else []:
            if not isinstance(blk, dict):
                continue
            if blk.get("type") == "tool_use" and blk.get("name") == "Bash":
                bash_uses += 1
            if blk.get("type") == "tool_result":
                text = blk.get("content")
                text = text if isinstance(text, str) else json.dumps(text)
                tool_results.append(text)
    # result.result holds only the last text block. The code word can be in an earlier one.
    answer = " ".join(blk.get("text") or "" for o in stream if o.get("type") == "assistant"
                      for blk in ((o.get("message") or {}).get("content") or []) if isinstance(blk, dict))
    def read(name):
        p = os.path.join(out, name)
        return open(p, encoding="utf-8").read().split() if os.path.exists(p) else []
    print("smoke: probe subtype %s, cost %.4f USD" % (result.get("subtype"), result.get("total_cost_usd") or 0))
    print("smoke: probe Bash tool uses: %d, tool results: %s" % (bash_uses, [t[:240] for t in tool_results] or "none"))
    created = os.path.exists(os.path.join(out, "probe", "out.txt"))
    # out.txt is also absent when the model makes no Bash call or a permission rule denies it.
    # So BLOCKS needs a tool result that names the hook failure.
    hook_said = any("onfailure" in t.lower() or "blocking" in t.lower() for t in tool_results)
    verdict = ("INCONCLUSIVE (no Bash tool use)" if bash_uses == 0 else "DOES NOT BLOCK" if created
               else "BLOCKS" if hook_said else "INCONCLUSIVE (no out.txt, no hook failure in the tool results)")
    print("smoke: MEASURE onFailure block with a missing command: %s (out.txt %s, marker hook ran %d times)" % (
        verdict, "created" if created else "absent", len(read("probe-marker.txt"))))
    print("smoke: MEASURE UserPromptSubmit additionalContext: %s (hook ran %d times)" % (
        "ACCEPTED" if "PELICAN-7" in answer else "NOT SEEN in the answer", len(read("probe-env.txt"))))
    print("smoke: MEASURE CREW_AGENT in a hook of plain claude -p: %s" % (read("probe-env.txt") or "hook did not run"))
    print("smoke: COST probe %.4f USD" % (result.get("total_cost_usd") or 0))

if sys.argv[1] == "run":
    check_run(sys.argv[2], float(sys.argv[3]), sys.argv[4])
else:
    check_probe(sys.argv[2])
EOF

# Install the kit from this checkout, so the shim runs the code under test.
"$PY" "$KIT/bin/crew" install --force >/dev/null || fail "crew install"
[ "$("$C" --version)" = "crew $("$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); import crew; print(crew.__version__)' "$KIT")" ] \
  || fail "the shim prints the wrong version"
say "shim $C: $("$C" --version)"

step_root() {
  say "== root: $ROOT"
  cd "$ROOT"
  [ -f .crew/crew.json ] || fail "no .crew/crew.json in $ROOT. Run crew init there first (WP7)"
  "$C" budget --probe || fail "crew budget --probe exited $?"
  CREW_CLAUDE_BIN="$OUT/claude-tee" CREW_SMOKE_LOG="$OUT/root" \
    "$C" run --max-usd 0.20 "List the open questions in .crew/STATE.md and stop." \
    || fail "crew run in the root exited $?"
  "$PY" "$OUT/check.py" run "$ROOT" 0.20 "$OUT/root" || fail "root run check"
  say "last ledger rows:"; tail -n 3 .crew/ledger.jsonl
  say "last 20 events:"; tail -n 20 "$HOME/.crew/events.jsonl"
}

step_temp() {
  local T="$OUT/repo" TID TASK
  say "== temp repo: $T"
  mkdir -p "$T" && cd "$T"
  git init -q -b dev
  git config user.name crew-smoke
  git config user.email crew-smoke@example.invalid
  echo "# smoke" > README.md
  "$C" init --lead-name Atlas --project-name smoke >/dev/null || fail "crew init in the temp repo"
  # A static hook script (its path is hashed, its log is not) records the environment that hooks see.
  cat > "$OUT/hook-env.sh" <<EOF
#!/bin/sh
cat >/dev/null
printf '%s %s\n' "\${CREW_AGENT:-unset}" "\${CREW_RUN_ID:-unset}" >> "$OUT/hook-env.txt"
exit 0
EOF
  # Temp repo only: the lead on haiku with no call reserve, so --max-usd 0.20 leaves a cap of 0.20.
  "$PY" - "$T" "$OUT/hook-env.sh" <<'EOF'
import json, os, sys
t, probe = sys.argv[1], sys.argv[2]
p = os.path.join(t, ".crew", "crew.json")
cfg = json.load(open(p))
lead = next(a for a in cfg["agents"] if a["id"] == cfg["lead"])
lead.update(model="haiku", effort="low")
cfg["budget"]["call_reserve_usd"] = {"default": 0.0}
json.dump(cfg, open(p, "w"), indent=2)
s = os.path.join(t, ".claude", "settings.json")
st = json.load(open(s))
hook = {"type": "command", "command": "sh " + probe, "timeout": 5}
st["hooks"]["SessionStart"].append({"hooks": [hook]})
st["hooks"]["PreToolUse"].append({"matcher": "*", "hooks": [hook]})
json.dump(st, open(s, "w"), indent=2)
EOF
  git add -A && git commit -qm "Initial commit"
  TID="$("$PY" -c 'import secrets, time; print(time.strftime("t-%Y%m%d-%H%M-") + secrets.token_hex(2))')"
  TASK="Smoke test. Do exactly these steps in this folder, with no worktree, no other agent, no huddle, no plan file, no retro and no session record:
1. Run: \"\$HOME\"/.crew/bin/crew route --task $TID --type code --paths hello.txt --json
2. Run: git checkout -b feature/smoke
3. Write the file hello.txt with the one line: hello from crew
4. Run: git add hello.txt && git commit -m \"Add hello.txt\"
Do not push. Then end with the crew_result line, with branch feature/smoke."
  CREW_CLAUDE_BIN="$OUT/claude-tee" CREW_SMOKE_LOG="$OUT/temp" \
    "$C" run --approved --task-id "$TID" --max-usd 0.20 "$TASK" || fail "crew run in the temp repo exited $?"
  "$PY" "$OUT/check.py" run "$T" 0.20 "$OUT/temp" || fail "temp run check"
  say "MEASURE CREW_AGENT in the hooks of crew run: $(sort "$OUT/hook-env.txt" 2>/dev/null | uniq -c | tr '\n' ' ' || true)"
  git log --all --oneline
  git rev-parse --verify -q refs/heads/feature/smoke >/dev/null || fail "no branch feature/smoke"
  [ "$(git rev-list --count dev..feature/smoke)" = 1 ] || fail "feature/smoke does not hold exactly one commit over dev"
  [ "$(git rev-list --count dev)" = 1 ] || fail "the lead committed on dev"
  git cat-file -e feature/smoke:hello.txt 2>/dev/null || fail "hello.txt is not in the commit on feature/smoke"
  git show --stat --format='%h %s' feature/smoke | head -5
  say "MEASURE commit with --permission-mode auto in -p: OK (1 new commit on feature/smoke, hello.txt in it)"
}

step_probe() {
  local P="$OUT/probe"
  say "== probe: $P"
  mkdir -p "$P/.claude" && cd "$P"
  cat > "$OUT/ups.sh" <<EOF
#!/bin/sh
cat >/dev/null
printf '%s\n' "\${CREW_AGENT:-unset}" >> "$OUT/probe-env.txt"
printf '%s' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Smoke code word: PELICAN-7."}}'
EOF
  cat > "$OUT/mark.sh" <<EOF
#!/bin/sh
cat >/dev/null
echo fired >> "$OUT/probe-marker.txt"
EOF
  cat > .claude/settings.json <<EOF
{"hooks": {
  "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "sh $OUT/ups.sh", "timeout": 5}]}],
  "PreToolUse": [{"matcher": "Bash", "hooks": [
    {"type": "command", "command": "/nonexistent-crew-smoke/bin/crew hook guard", "timeout": 10, "onFailure": "block"},
    {"type": "command", "command": "sh $OUT/mark.sh", "timeout": 5}]}]}}
EOF
  CREW_AGENT=smoke-probe "$REAL_CLAUDE" -p --model haiku --max-budget-usd 0.20 --output-format stream-json --verbose \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' --permission-mode auto --allowedTools Bash \
    > "$OUT/probe.jsonl" 2> "$OUT/probe.err" <<'EOF' || true
First, say the smoke code word from your context, or say NONE. Then run this exact Bash command once: echo hi > out.txt
Do not retry it if it fails. Then say in one line whether the command ran.
EOF
  "$PY" "$OUT/check.py" probe "$OUT" || fail "probe check"
}

case "$STEP" in
  all) step_root; step_temp; step_probe ;;
  root) step_root ;;
  temp) step_temp ;;
  probe) step_probe ;;
esac
say "PASS ($STEP)"
