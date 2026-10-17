# /// script
# requires-python = ">=3.11"
# dependencies = ["pyarrow>=17"]
# ///
"""Build the public disfluency suite from DisfluencySpeech (amaai-lab, Apache-2.0).

    uv run eval/text-cleanup/make-disfluency-cases.py            # text suite -> disfluency-cases.jsonl
    uv run eval/text-cleanup/make-disfluency-cases.py --audio    # + real recordings -> .eval-scratch/

No dictation vendor publishes its cleanup eval set (Wispr Flow, Superwhisper and
AssemblyAI's open bench all keep the data private), so this is the public anchor
beside our own hand-written cases. DisfluencySpeech is one speaker re-reading
Switchboard turns, with three transcripts per clip:

- transcript_a: every word said, fillers and restarts included   -> our input
- transcript_c: fillers, editing terms and false starts removed   -> our reference

Each case passes when the cleaned output is within `max_reference_wer` of
transcript_c. The bar is half the gap the raw input starts with, floored at 10%,
so a no-op cannot pass a case that has real disfluency in it, and a fluent case
still fails when the model rewrites it. WER is case- and punctuation-blind, so
the reference's casing quirks cost nothing.

Only the 250-clip **test** split is used, so a model fine-tuned on the train
split cannot have seen these turns. The output is deterministic: re-running it
rewrites the same file byte for byte.
"""

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

import pyarrow.parquet as pq

DATASET = "amaai-lab/DisfluencySpeech"
TEST_URL = f"https://huggingface.co/datasets/{DATASET}/resolve/main/data/test-00000-of-00001.parquet"
HERE = Path(__file__).resolve().parent
SCRATCH = HERE / ".eval-scratch"


def words(text: str) -> list[str]:
    # Same normalization as EvalScoreKit.WER, so the bar written here is the
    # number the scorer will compare against.
    return [w for w in re.split(r"[^\w']+", text.lower().replace("_", " ")) if w]


def wer(reference: str, hypothesis: str) -> float:
    r, h = words(reference), words(hypothesis)
    if not r:
        return 0.0 if not h else 1.0
    prev = list(range(len(h) + 1))
    for i, rw in enumerate(r):
        cur = [i + 1]
        for j, hw in enumerate(h):
            cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (rw != hw)))
        prev = cur
    return prev[-1] / len(r)


def spoken(text: str) -> str:
    """transcript_a as a transcriber would hand it over: the cut-off fragment is
    heard as a word ("bam-," -> "bam,"), everything else stays as said."""
    text = re.sub(r"(\w)-(?=[\s,.?!]|$)", r"\1", text)
    return re.sub(r"\s+", " ", text).strip()


def tidy_reference(text: str) -> str:
    """transcript_c with the seams its deletions left: stray commas, a lowercase
    sentence start, a double space. None of this changes a word."""
    text = re.sub(r"(\w)-(?=[\s,.?!]|$)", r"\1", text)
    text = re.sub(r"\s+,", ",", text)
    text = re.sub(r",\s*([.?!])", r"\1", text)
    text = re.sub(r"^[,\s]+", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"(^|[.?!]\s+)([a-z])", lambda m: m.group(1) + m.group(2).upper(), text)


def fetch(dest: Path) -> Path:
    if dest.exists():
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"fetching {TEST_URL}", file=sys.stderr)
    urllib.request.urlretrieve(TEST_URL, dest)
    return dest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--audio", action="store_true",
                        help="also write the recordings and .eval-scratch/disfluency_audio_cases.jsonl")
    parser.add_argument("--out", type=Path, default=HERE / "disfluency-cases.jsonl")
    args = parser.parse_args()

    parquet = fetch(SCRATCH / "disfluencyspeech-test.parquet")
    columns = ["transcript_a", "transcript_c"] + (["audio"] if args.audio else [])
    rows = pq.read_table(parquet, columns=columns).to_pylist()

    cases, audio_cases = [], []
    for index, row in enumerate(rows):
        said = spoken(row["transcript_a"])
        reference = tidy_reference(row["transcript_c"])
        if not words(said) or not words(reference):
            continue
        gap = wer(reference, said)
        case_id = f"dsp-{index:03d}"
        case = {
            "id": case_id,
            "category": "public-disfluency" if gap > 0 else "public-fluent",
            "input": {"text": said},
            "targets": ["light"],
            "reference": reference,
            "max_reference_wer": round(max(0.10, gap / 2), 3),
            "note": f"DisfluencySpeech test #{index}, input starts {gap:.0%} from the reference",
        }
        cases.append(case)
        if args.audio:
            wav = SCRATCH / "disfluency-audio" / f"{case_id}.wav"
            wav.parent.mkdir(parents=True, exist_ok=True)
            wav.write_bytes(row["audio"]["bytes"])
            audio_cases.append({**case, "id": f"dsp-audio-{index:03d}",
                                "input": {"audio": str(wav)}, "asr_reference": said})

    args.out.write_text("".join(json.dumps(c, ensure_ascii=False) + "\n" for c in cases))
    noisy = sum(c["category"] == "public-disfluency" for c in cases)
    print(f"wrote {len(cases)} cases ({noisy} with disfluency) -> {args.out}", file=sys.stderr)
    if args.audio:
        path = SCRATCH / "disfluency_audio_cases.jsonl"
        path.write_text("".join(json.dumps(c, ensure_ascii=False) + "\n" for c in audio_cases))
        print(f"wrote {len(audio_cases)} audio cases -> {path}", file=sys.stderr)


if __name__ == "__main__":
    main()
