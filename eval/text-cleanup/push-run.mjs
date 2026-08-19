#!/usr/bin/env node
// Post a finished eval run into the public history at /eval.
//
//   node push-run.mjs <results.json> [cases.jsonl] [label]
//
// The history used to live in a separate SvelteKit dashboard on its own Vercel
// account; it is now a route on the landing site, which is why this script
// moved out of `eval/dashboard/scripts/` and no longer needs that app checked
// out or running.
//
//   DASHBOARD_URL      where to post   (default: https://whisper.corkkam.com)
//   EVAL_INGEST_TOKEN  the shared secret the route checks. Required: the route
//                      fails closed, so without it every upload is refused.
//                      Also read from this repo's .env if not in the
//                      environment. Never commit a value for it.
import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";

const [resultsPath, casesPath, label] = process.argv.slice(2);
if (!resultsPath) {
  console.error("usage: node push-run.mjs <results.json> [cases.jsonl] [label]");
  process.exit(2);
}

// Node does not auto-load dotenv, and this is usually run from run-eval.sh.
function ingestToken() {
  for (const name of ["EVAL_INGEST_TOKEN", "INGEST_TOKEN"]) {
    if (process.env[name]) return process.env[name];
  }
  try {
    const env = readFileSync(new URL("../../.env", import.meta.url), "utf8");
    const match = env.match(/^EVAL_INGEST_TOKEN\s*=\s*"?([^"\n]+)"?/m);
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

const base = (process.env.DASHBOARD_URL || "https://whisper.corkkam.com").replace(/\/+$/, "");
const token = ingestToken();
const results = JSON.parse(readFileSync(resultsPath, "utf8"));
const cases = casesPath ? readFileSync(casesPath, "utf8") : null;

const git = (cmd) => {
  try {
    return execSync(cmd, { stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
  } catch {
    return null;
  }
};

const response = await fetch(`${base}/api/eval/ingest`, {
  method: "POST",
  headers: {
    "content-type": "application/json",
    ...(token ? { "x-ingest-token": token } : {}),
  },
  body: JSON.stringify({
    results,
    cases,
    label: label ?? null,
    gitCommit: git("git rev-parse HEAD"),
    branch: git("git rev-parse --abbrev-ref HEAD"),
  }),
});

if (!response.ok) {
  console.error(`ingest failed: ${response.status} ${await response.text()}`);
  if (!token) console.error("EVAL_INGEST_TOKEN is not set — the route refuses unauthenticated uploads.");
  process.exit(1);
}
const out = await response.json();
console.log(`stored run ${out.id} — ${out.totalRuns} rows, ${out.totalCases} cases`);
// A case the rules file does not cover can only fail on word error, so the
// wrong cases.jsonl scores higher instead of erroring. Audio ids live only in
// the generated .eval-scratch/audio_cases.jsonl.
if (out.unmatchedCases > 0) {
  console.warn(
    `⚠ ${out.unmatchedCases} of ${out.totalCases} cases have no keyword rule in ` +
      `${casesPath ?? "(no cases file sent)"} — this run is graded on word error alone for those. ` +
      `For an audio run, pass .eval-scratch/audio_cases.jsonl.`
  );
}
console.log(`view: ${base}/eval/${out.id}`);
