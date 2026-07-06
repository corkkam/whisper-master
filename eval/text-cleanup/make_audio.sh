#!/usr/bin/env bash
# Generate audio eval inputs into .eval-scratch/ (git-ignored) — disposable glue.
#   - TTS every text case via macOS `say` -> m4a, with an exact asr_reference.
#   - Augment (only if ffmpeg is installed): a Bluetooth-HFP variant and a pink-
#     noise variant for a representative subset (realistic / disfluency cases).
#   - Common Voice slice: see fetch_common_voice below (opt-in; needs network).
#
# Requires: `say` (built-in). `ffmpeg` is optional and used only for augmentation.
# Usage: bash make_audio.sh [cases.jsonl]   (defaults to ./cases.jsonl)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CASES="${1:-$HERE/cases.jsonl}"
SCRATCH="$HERE/.eval-scratch"
TTS="$SCRATCH/audio/tts"
AUG="$SCRATCH/audio/aug"
MANIFEST="$SCRATCH/audio_cases.jsonl"
mkdir -p "$TTS" "$AUG"

python3 - "$CASES" "$TTS" "$AUG" "$MANIFEST" "$(command -v ffmpeg || true)" <<'PY'
import json, os, subprocess, sys
cases_path, tts_dir, aug_dir, manifest, ffmpeg = sys.argv[1:6]

def say(text, out):
    subprocess.run(["say", "-o", out, text], check=True)

def hfp(src, dst):  # Bluetooth hands-free profile: mono, 8 kHz, telephone band.
    subprocess.run([ffmpeg, "-y", "-i", src, "-af",
        "aformat=channel_layouts=mono,aresample=8000,highpass=f=300,lowpass=f=3400", dst],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def noisy(src, dst, amp):  # additive pink noise for a robustness point.
    subprocess.run([ffmpeg, "-y", "-i", src, "-f", "lavfi", "-i",
        f"anoisesrc=color=pink:amplitude={amp}", "-filter_complex",
        "[0:a][1:a]amix=inputs=2:duration=first", dst],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

rows = []
def emit(cid, category, audio, ref, c, note):
    rows.append({"id": cid, "category": category, "input": {"audio": audio},
                 "asr_reference": ref, "targets": c.get("targets", ["light", "polish"]),
                 "must_contain": c.get("must_contain", []),
                 "must_not_contain": c.get("must_not_contain", []), "note": note})

cases = [json.loads(l) for l in open(cases_path) if l.strip()]
n_tts = n_aug = 0
for c in cases:
    inp = c["input"] if isinstance(c["input"], dict) else {"text": c["input"]}
    text = inp.get("text")
    if not text:
        continue  # audio-only source cases are handled elsewhere
    cid = c["id"]
    m4a = os.path.join(tts_dir, cid + ".m4a")
    say(text, m4a)
    emit("tts-" + cid, c.get("category", "x"), m4a, text, c, "tts:" + c.get("note", ""))
    n_tts += 1
    if ffmpeg and c.get("category") in ("realistic", "disfluency"):
        h = os.path.join(aug_dir, cid + "-hfp.m4a"); hfp(m4a, h)
        emit("hfp-" + cid, c.get("category", "x"), h, text, c, "bluetooth-hfp")
        z = os.path.join(aug_dir, cid + "-noisy.m4a"); noisy(m4a, z, 0.05)
        emit("noisy-" + cid, c.get("category", "x"), z, text, c, "pink-noise")
        n_aug += 2

with open(manifest, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
print(f"tts={n_tts} augmented={n_aug} ffmpeg={'yes' if ffmpeg else 'no (augmentation skipped; brew install ffmpeg to enable)'}")
print(f"manifest: {manifest}")
PY

# --- Common Voice slice (opt-in; real-human WER anchor) ---
# A CC0 slice with transcripts, for real-accuracy numbers. Left as a documented
# opt-in step because it needs the network and a dataset URL:
#   1) download a Common Voice `.tar.gz` delta into $SCRATCH/cv/
#   2) for each row of its validated.tsv (path, sentence), append an audio case
#      {input:{audio:<clip>}, asr_reference:<sentence>} to $MANIFEST.
fetch_common_voice() { echo "fetch_common_voice: wire a CC0 slice URL when ready" >&2; }
