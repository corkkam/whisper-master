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
Switchboard turns. Two of its transcripts are used:

- transcript_a: every word said, fillers and restarts included   -> our input
- transcript_annotated: the Switchboard markup                    -> our reference

The reference drops what the cleanup pass is there to remove and nothing else:
fillers (`{F uh}`), the abandoned half of a restart (`[ reparandum + repair ]`
keeps the repair) and an editing term standing between the two halves. Discourse
markers ("you know", "well"), editing terms elsewhere ("I mean"), conjunctions
and asides stay, because FillerWordFilter keeps them on purpose. The dataset's own
transcript_c deletes those as well, and grading against it failed faithful output
for keeping "I mean" and handed the arena to whichever model ignored the policy.

**The pass bars are not computed here.** Each case is graded against what the
model actually receives, which is the input after the app's deterministic passes
(FillerWordFilter strips "um" before any model sees it). Those passes are Swift,
so this script writes input and reference to .eval-scratch/ and then runs
`swift test --filter DisfluencySuiteTests/testRegenerateTheSuite`, which passes
both through `LabDeterministicPipeline` and writes `category` and
`max_reference_wer`. One copy of the filler rules, not a Python imitation of them.

Only the 250-clip **test** split is used, so a model fine-tuned on the train split
cannot have seen these turns. The download is pinned to one dataset revision and
checked against its SHA-256, so re-running rewrites the same file byte for byte.

Cite the dataset as its card asks (https://huggingface.co/datasets/amaai-lab/DisfluencySpeech):
Kyra Wang and Dorien Herremans, "DisfluencySpeech -- Single-Speaker Conversational
Speech Dataset with Paralanguage", arXiv:2406.08820, 2024.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

import pyarrow.parquet as pq

DATASET = "amaai-lab/DisfluencySpeech"
REVISION = "b7da294fe3a70dd96df6640893f2a5dfc2c87638"
TEST_URL = f"https://huggingface.co/datasets/{DATASET}/resolve/{REVISION}/data/test-00000-of-00001.parquet"
TEST_SHA256 = "e78837be393206fc0ae6a0cefb4ec8c942c3e26401640eb8af67cf0dac21b4b0"
HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SCRATCH = HERE / ".eval-scratch"


def words(text: str) -> list[str]:
    return [w for w in re.split(r"[^\w']+", text.lower().replace("_", " ")) if w]


def spoken(text: str) -> str:
    """transcript_a as a transcriber would hand it over: the cut-off fragment is
    heard as a word ("bam-," -> "bam,"), everything else stays as said."""
    text = re.sub(r"(\w)-(?=[\s,.?!]|$)", r"\1", text)
    return re.sub(r"\s+", " ", text).strip()


INNERMOST_RESTART = re.compile(r"\[([^\[\]]*)\]")
INTERREGNUM = re.compile(r"^\s*(\{[EF][^{}]*\}\s*)+")


def repair(restart: str) -> str:
    """`reparandum + repair` -> the repair, minus the editing term or filler that
    opens it ("[ Tuesday, + {E I mean} Wednesday ]" -> "Wednesday"). A bracket with
    no interruption point is kept whole."""
    if "+" not in restart:
        return restart
    return INTERREGNUM.sub("", restart.split("+", 1)[1])


def fluent(annotated: str) -> str:
    """The reference: transcript_annotated with fillers and false starts removed."""
    text = re.sub(r"<[^>]*>", " ", annotated)           # laughter, breathing, ...
    text = text.replace("((", " ").replace("))", " ")   # transcriber unsure of the words
    # Restarts nest ("[ [ a + b ] + c ]"), so resolve the innermost first.
    while match := INNERMOST_RESTART.search(text):
        text = f"{text[:match.start()]} {repair(match.group(1))} {text[match.end():]}"
    # A restart the turn ends inside has no "]": its repair runs to the end.
    text = re.sub(r"\[[^\[\]+]*\+", " ", text)
    text = text.replace("[", " ").replace("]", " ")
    text = re.sub(r"\{F[^{}]*\}", " ", text)            # fillers go
    text = re.sub(r"\{[A-Z]\s?([^{}]*)\}", r" \1 ", text)  # D, E, C, A stay
    text = re.sub(r"(?<![\w-])-+/?(?![\w])", " ", text)  # interruption dashes
    return tidy(text)


def tidy(text: str) -> str:
    """The seams the deletions leave: stray commas, a lowercase sentence start, a
    double space. None of this changes a word."""
    text = re.sub(r"(\w)-(?=[\s,.?!]|$)", r"\1", text)
    text = re.sub(r"\s+([,.?!])", r"\1", text)
    text = re.sub(r",(\s*,)+", ",", text)
    text = re.sub(r",\s*([.?!])", r"\1", text)
    text = re.sub(r"^[,.\s]+", "", text)
    text = re.sub(r"[,\s]+$", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"(^|[.?!]\s+)([a-z])", lambda m: m.group(1) + m.group(2).upper(), text)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch(dest: Path) -> Path:
    """Download to a .part file and rename only once the digest matches, so an
    interrupted or tampered download is never read as the dataset."""
    if dest.exists() and sha256(dest) == TEST_SHA256:
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    print(f"fetching {TEST_URL}", file=sys.stderr)
    urllib.request.urlretrieve(TEST_URL, part)
    if (actual := sha256(part)) != TEST_SHA256:
        part.unlink()
        sys.exit(f"{TEST_URL}: sha256 {actual}, expected {TEST_SHA256}")
    part.replace(dest)
    return dest


def grade_in_swift(raw: Path, out: Path) -> None:
    env = {**os.environ, "WM_DISFLUENCY_RAW": str(raw), "WM_DISFLUENCY_OUT": str(out)}
    command = ["swift", "test", "--filter", "DisfluencySuiteTests/testRegenerateTheSuite"]
    print("grading through LabDeterministicPipeline: " + " ".join(command), file=sys.stderr)
    subprocess.run(command, cwd=REPO, env=env, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--audio", action="store_true",
                        help="also write the recordings and .eval-scratch/disfluency_audio_cases.jsonl")
    parser.add_argument("--out", type=Path, default=HERE / "disfluency-cases.jsonl")
    args = parser.parse_args()

    parquet = fetch(SCRATCH / "disfluencyspeech-test.parquet")
    columns = ["transcript_annotated", "transcript_a"] + (["audio"] if args.audio else [])
    rows = pq.read_table(parquet, columns=columns).to_pylist()

    raw_cases, said_by_id, audio_by_id = [], {}, {}
    for index, row in enumerate(rows):
        said = spoken(row["transcript_a"])
        reference = fluent(row["transcript_annotated"])
        if not words(said) or not words(reference):
            continue
        case_id = f"dsp-{index:03d}"
        raw_cases.append({"id": case_id, "input": said, "reference": reference,
                          "note": f"DisfluencySpeech test #{index}"})
        said_by_id[case_id] = said
        if args.audio:
            audio_by_id[case_id] = row["audio"]["bytes"]

    raw = SCRATCH / "disfluency-raw.jsonl"
    raw.write_text("".join(json.dumps(c, ensure_ascii=False) + "\n" for c in raw_cases))
    grade_in_swift(raw, args.out.resolve())

    cases = [json.loads(line) for line in args.out.read_text().splitlines() if line.strip()]
    graded = sum(c["category"] == "public-disfluency" for c in cases)
    print(f"wrote {len(cases)} cases ({graded} a no-op fails, {len(cases) - graded} don't-damage) -> {args.out}",
          file=sys.stderr)

    if args.audio:
        audio_cases = []
        for case in cases:
            index = case["id"].removeprefix("dsp-")
            wav = SCRATCH / "disfluency-audio" / f"{case['id']}.wav"
            wav.parent.mkdir(parents=True, exist_ok=True)
            wav.write_bytes(audio_by_id[case["id"]])
            audio_cases.append({**case, "id": f"dsp-audio-{index}",
                                "input": {"audio": str(wav)}, "asr_reference": said_by_id[case["id"]]})
        path = SCRATCH / "disfluency_audio_cases.jsonl"
        path.write_text("".join(json.dumps(c, ensure_ascii=False) + "\n" for c in audio_cases))
        print(f"wrote {len(audio_cases)} audio cases -> {path}", file=sys.stderr)


if __name__ == "__main__":
    main()
