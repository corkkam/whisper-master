#!/usr/bin/env node
// Turn the generated audio manifest into a transcription-only suite.
//
//   bash make_audio.sh                       # writes .eval-scratch/audio_cases.jsonl
//   node make-transcription-cases.mjs        # writes .eval-scratch/transcription-cases.jsonl
//   node make-transcription-cases.mjs --real # LibriSpeech clips only
//
// Same clips, one target: `transcription`. The speech model is graded on word
// error against `asr_reference` and nothing else — no cleanup in the loop, no
// keyword rules. That is the point. Today ASR only appears as a side effect of
// an audio cleanup case, so a Parakeet regression is invisible unless it also
// happens to break a keyword rule, and a cleanup change moves the same number.
//
// `--real` keeps only the LibriSpeech clips, which are the recordings of actual
// people. It is the number to trust and the fastest suite to run.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const scratch = join(here, ".eval-scratch");
const input = process.env.AUDIO_CASES ?? join(scratch, "audio_cases.jsonl");
const output = process.env.OUT ?? join(scratch, "transcription-cases.jsonl");
const realOnly = process.argv.includes("--real");

let lines;
try {
  lines = readFileSync(input, "utf8").split("\n").filter((l) => l.trim());
} catch {
  console.error(`${input} not found. Generate it first: bash make_audio.sh`);
  process.exit(1);
}

const out = [];
let skipped = 0;
for (const line of lines) {
  let c;
  try {
    c = JSON.parse(line);
  } catch {
    skipped++;
    continue;
  }
  // A case with no audio or no reference cannot be scored on hearing.
  if (!c.input?.audio || !c.asr_reference) {
    skipped++;
    continue;
  }
  if (realOnly && !String(c.id).startsWith("ls-")) continue;
  out.push(
    JSON.stringify({
      id: c.id,
      category: c.category ?? "transcription",
      input: { audio: c.input.audio },
      asr_reference: c.asr_reference,
      targets: ["transcription"],
    })
  );
}

writeFileSync(output, out.join("\n") + "\n");
console.log(`${out.length} case(s) → ${output}${skipped ? ` (${skipped} skipped)` : ""}`);
if (out.length === 0) console.error("nothing to grade — is the manifest empty?");
