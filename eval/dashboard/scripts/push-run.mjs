#!/usr/bin/env node
// Post an eval run into the dashboard's history.
// Usage: node scripts/push-run.mjs <results.json> [cases.jsonl] [label]
//   DASHBOARD_URL overrides the target (default http://localhost:5173).
//   INGEST_TOKEN authenticates against the protected /api/ingest (also read
//   from the dashboard's .env if not in the environment).
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';

const [resultsPath, casesPath, label] = process.argv.slice(2);
if (!resultsPath) {
  console.error('usage: node scripts/push-run.mjs <results.json> [cases.jsonl] [label]');
  process.exit(2);
}

// Ingest is token-protected on the public deploy. Take the token from the env,
// else read it from the dashboard's .env (Node doesn't auto-load dotenv).
function ingestToken() {
  if (process.env.INGEST_TOKEN) return process.env.INGEST_TOKEN;
  try {
    const m = readFileSync(new URL('../.env', import.meta.url), 'utf8').match(
      /^INGEST_TOKEN\s*=\s*"?([^"\n]+)"?/m
    );
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

const base = process.env.DASHBOARD_URL || 'http://localhost:5173';
const token = ingestToken();
const results = JSON.parse(readFileSync(resultsPath, 'utf8'));
const cases = casesPath ? readFileSync(casesPath, 'utf8') : null;

const git = (cmd) => {
  try {
    return execSync(cmd, { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
  } catch {
    return null;
  }
};

const res = await fetch(base + '/api/ingest', {
  method: 'POST',
  headers: {
    'content-type': 'application/json',
    ...(token ? { 'x-ingest-token': token } : {})
  },
  body: JSON.stringify({
    results,
    cases,
    label: label ?? null,
    gitCommit: git('git rev-parse HEAD'),
    branch: git('git rev-parse --abbrev-ref HEAD')
  })
});

if (!res.ok) {
  console.error(`ingest failed: ${res.status} ${await res.text()}`);
  process.exit(1);
}
const out = await res.json();
console.log(`stored run ${out.id} — ${out.totalRuns} rows, ${out.totalCases} cases`);
console.log(`view: ${base}/runs/${out.id}`);
