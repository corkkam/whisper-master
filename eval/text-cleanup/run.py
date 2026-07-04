#!/usr/bin/env python3
"""Replay the text-cleanup scenarios through one or more local Ollama models
and score them, so we can pick the smallest model that's actually reliable.

Usage:
    python3 run.py --models gemma3:1b,qwen2.5:1.5b,llama3.2:3b
    python3 run.py                      # uses DEFAULT_MODELS below

Needs Ollama running locally (the app or `ollama serve`) and the models pulled
(`ollama pull <name>`). No pip dependencies.

Writes report.md (human-readable comparison) and raw.json next to this script.
"""
import argparse
import json
import os
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://localhost:11434") + "/api/chat"

DEFAULT_MODELS = [
    "gemma3:1b",
    "llama3.2:1b",
    "qwen2.5:1.5b",
    "qwen2.5:3b",
    "llama3.2:3b",
]


def load_cases(path):
    cases = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                cases.append(json.loads(line))
    return cases


def call_ollama(model, system, user, timeout=120):
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": False,
        "options": {"temperature": 0.2, "num_predict": 200},
    }).encode()
    req = urllib.request.Request(OLLAMA_URL, data=body, headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    wall = time.time() - t0
    text = data.get("message", {}).get("content", "").strip()
    eval_count = data.get("eval_count", 0)
    eval_dur = data.get("eval_duration", 0) or 1
    tok_s = eval_count / (eval_dur / 1e9) if eval_count else 0.0
    return text, wall, tok_s


def score(case, output):
    """Auto-pass only when every must_contain is present and no must_not_contain
    appears (case-insensitive). Judge cases are never auto-scored."""
    if case.get("judge"):
        return None
    low = output.lower()
    for needle in case.get("must_contain", []):
        if needle.lower() not in low:
            return False
    for bad in case.get("must_not_contain", []):
        if bad.lower() in low:
            return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default=",".join(DEFAULT_MODELS))
    ap.add_argument("--cases", default=os.path.join(HERE, "cases.jsonl"))
    ap.add_argument("--prompt", default=os.path.join(HERE, "prompt.txt"))
    args = ap.parse_args()

    models = [m.strip() for m in args.models.split(",") if m.strip()]
    system = open(args.prompt).read()
    cases = load_cases(args.cases)

    results = {}  # model -> list of {case, output, wall, tok_s, passed}
    for model in models:
        print(f"\n=== {model} ===")
        rows = []
        for case in cases:
            try:
                out, wall, tok_s = call_ollama(model, system, case["input"])
                passed = score(case, out)
            except urllib.error.HTTPError as e:
                out, wall, tok_s, passed = f"[HTTP {e.code}: pull the model?]", 0, 0, False
            except Exception as e:  # noqa: BLE001
                out, wall, tok_s, passed = f"[error: {e}]", 0, 0, False
            mark = "?" if passed is None else ("PASS" if passed else "FAIL")
            print(f"  [{mark:4}] {case['id']:22} {wall:5.1f}s  {out[:70]}")
            rows.append({"case": case, "output": out, "wall": wall, "tok_s": tok_s, "passed": passed})
        results[model] = rows

    write_report(results, cases)


def write_report(results, cases):
    lines = ["# Text-cleanup model comparison\n"]

    # Summary
    lines.append("## Summary\n")
    lines.append("| model | auto-passed | avg latency | avg tok/s |")
    lines.append("|---|---|---|---|")
    for model, rows in results.items():
        auto = [r for r in rows if r["passed"] is not None]
        passed = sum(1 for r in auto if r["passed"])
        walls = [r["wall"] for r in rows if r["wall"] > 0]
        toks = [r["tok_s"] for r in rows if r["tok_s"] > 0]
        avg_wall = sum(walls) / len(walls) if walls else 0
        avg_tok = sum(toks) / len(toks) if toks else 0
        lines.append(f"| {model} | {passed}/{len(auto)} | {avg_wall:.1f}s | {avg_tok:.0f} |")
    lines.append("\n_Judge cases (ambiguous) are excluded from auto-pass — eyeball them below._\n")

    # Per-case detail
    lines.append("## Per-case outputs\n")
    for i, case in enumerate(cases):
        tag = " _(human judge)_" if case.get("judge") else ""
        lines.append(f"### {case['id']} — {case['category']}{tag}")
        lines.append(f"- **input:** {case['input']}")
        lines.append(f"- **want:** {case['note']}")
        for model, rows in results.items():
            r = rows[i]
            mark = "?" if r["passed"] is None else ("✓" if r["passed"] else "✗")
            lines.append(f"- `{model}` {mark} → {r['output']}")
        lines.append("")

    report = os.path.join(HERE, "report.md")
    with open(report, "w") as f:
        f.write("\n".join(lines))
    with open(os.path.join(HERE, "raw.json"), "w") as f:
        json.dump({m: [{**r, "case": r["case"]["id"]} for r in rows] for m, rows in results.items()}, f, indent=2)
    print(f"\nwrote {report}")


if __name__ == "__main__":
    main()
