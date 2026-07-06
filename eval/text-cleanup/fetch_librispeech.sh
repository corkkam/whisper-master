#!/usr/bin/env bash
# Download a slice of LibriSpeech dev-clean (openslr.org, CC BY 4.0 — the
# canonical ASR benchmark, real human read speech with ground-truth transcripts)
# into .eval-scratch/, convert to m4a, and write librispeech_cases.jsonl — the
# real-accuracy WER anchor to complement the (optimistic) TTS audio.
#
# Requires: curl, ffmpeg. Slice size via LIBRISPEECH_N (default 20). Everything
# lands in git-ignored scratch; the tarball is deleted after extraction.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$HERE/.eval-scratch"
SRC="$SCRATCH/librispeech"
OUTDIR="$SCRATCH/audio/librispeech"
MANIFEST="$SCRATCH/librispeech_cases.jsonl"
N="${LIBRISPEECH_N:-20}"
URL="https://www.openslr.org/resources/12/dev-clean.tar.gz"
mkdir -p "$SRC" "$OUTDIR"

command -v ffmpeg >/dev/null || { echo "ffmpeg required: brew install ffmpeg" >&2; exit 1; }

if [ ! -d "$SRC/LibriSpeech" ]; then
  echo "downloading LibriSpeech dev-clean (~337 MB) from openslr.org..."
  curl -L --fail -o "$SRC/dev-clean.tar.gz" "$URL"
  echo "extracting..."
  tar xzf "$SRC/dev-clean.tar.gz" -C "$SRC"
  rm -f "$SRC/dev-clean.tar.gz"
fi

python3 - "$SRC/LibriSpeech/dev-clean" "$OUTDIR" "$MANIFEST" "$N" <<'PY'
import glob, json, os, subprocess, sys
root, outdir, manifest, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
rows = []
# Each *.trans.txt line is "<utt-id> TRANSCRIPT IN CAPS".
for trans in sorted(glob.glob(os.path.join(root, "*", "*", "*.trans.txt"))):
    base = os.path.dirname(trans)
    for line in open(trans):
        uid, text = line.strip().split(" ", 1)
        flac = os.path.join(base, uid + ".flac")
        if not os.path.exists(flac):
            continue
        m4a = os.path.join(outdir, uid + ".m4a")
        subprocess.run(["ffmpeg", "-y", "-i", flac, m4a],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        rows.append({"id": "ls-" + uid, "category": "librispeech",
                     "input": {"audio": m4a}, "asr_reference": text.lower(),
                     "targets": ["light"],  # real-accuracy WER anchor; cleanup mode is irrelevant
                     "must_contain": [], "must_not_contain": [], "note": "librispeech dev-clean"})
        if len(rows) >= n:
            break
    if len(rows) >= n:
        break
with open(manifest, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
print(f"librispeech: {len(rows)} clips -> {manifest}")
PY
