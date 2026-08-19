#!/usr/bin/env bash
#
# One command: run the in-app eval end to end, then publish the result to the
# public history at whisper.corkkam.com/eval.
#
#   bash run-eval.sh [cases.jsonl] [label]
#
# Defaults: cases = ./cases.jsonl, label = "eval <timestamp>".
# Destination suite: bash run-eval.sh ./flow-cases.jsonl "flow destinations"
#
# Env overrides:
#   APP            path to the built .app   (default: /Applications/Whisper Master.app)
#   OUT            results.json output path (default: ./.eval-scratch/results.json)
#   DASHBOARD_URL  where to POST the run    (default: https://whisper.corkkam.com)
#   TIMEOUT        seconds to wait for the run to finish (default: 1200)
#   NO_PUSH=1      run the eval but skip the push (just write results.json)
#
# The push needs EVAL_INGEST_TOKEN, in the environment or in this repo's .env.
# The route fails closed, so without it the upload is refused.
#
# Why the launchctl/open dance: the eval runs *inside the app* and reads its
# config from env at launch. A directly-exec'd bundle fails TCC's Info.plist
# lookup and the mesh Bluetooth scan hard-crashes, so we hand env to
# LaunchServices via `launchctl setenv` and start the app with `open`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cases_in="${1:-$here/cases.jsonl}"
label="${2:-eval $(date '+%Y-%m-%d %H:%M')}"
app="${APP:-/Applications/Whisper Master.app}"
out="${OUT:-$here/.eval-scratch/results.json}"
timeout="${TIMEOUT:-1200}"
dashboard_url="${DASHBOARD_URL:-https://whisper.corkkam.com}"

# Absolute paths — EvalRunner + launchctl need them.
cases="$(cd "$(dirname "$cases_in")" && pwd)/$(basename "$cases_in")"
mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

[ -f "$cases" ] || { echo "✗ cases file not found: $cases" >&2; exit 1; }
[ -d "$app" ]   || { echo "✗ app not found: $app  (build it: bash Scripts/bundle.sh)" >&2; exit 1; }

echo "▶ cases : $cases"
echo "▶ app   : $app"
echo "▶ out   : $out"

# Heads-up if the site isn't reachable — the eval still runs and the results
# are saved; you can push them later.
if [ "${NO_PUSH:-0}" != "1" ] && ! curl -sf -o /dev/null "$dashboard_url"; then
  echo "⚠ not reachable at $dashboard_url"
  echo "  the eval will still run; results are saved and can be pushed afterwards."
fi

# The runner reads env at launch, so quit any running instance and start clean.
osascript -e 'quit app "Whisper Master"' 2>/dev/null || true
sleep 1

# Remove any stale results so we can detect *this* run's write.
rm -f "$out"

launchctl setenv WM_EVAL_CASES "$cases"
launchctl setenv WM_EVAL_OUT "$out"
cleanup() { launchctl unsetenv WM_EVAL_CASES || true; launchctl unsetenv WM_EVAL_OUT || true; }
trap cleanup EXIT

open -a "$app"
echo "▶ launched — loading the cleanup model, then running every case (≤${timeout}s)…"

# results.json is written once at the very end. Wait for it to appear and hold
# steady (mtime+size unchanged across a poll) before treating the run as done.
waited=0; last=""
while [ "$waited" -lt "$timeout" ]; do
  if [ -f "$out" ]; then
    stamp="$(stat -f '%m %z' "$out")"
    [ "$stamp" = "$last" ] && break
    last="$stamp"
  fi
  sleep 3; waited=$((waited + 3))
done

[ -f "$out" ] || { echo "✗ timed out after ${timeout}s — no results.json written" >&2; exit 1; }
rows="$(grep -c '"id"' "$out" 2>/dev/null || true)"
echo "✓ eval finished — ${rows:-?} rows → $out"

if [ "${NO_PUSH:-0}" = "1" ]; then
  echo "NO_PUSH set — skipping the push."
  exit 0
fi

echo "▶ publishing to $dashboard_url/eval …"
if ! DASHBOARD_URL="$dashboard_url" node "$here/push-run.mjs" "$out" "$cases" "$label"; then
  echo "✗ push failed. Results are safe at $out; re-push later with:" >&2
  echo "  DASHBOARD_URL=$dashboard_url node $here/push-run.mjs \"$out\" \"$cases\" \"$label\"" >&2
  exit 1
fi
