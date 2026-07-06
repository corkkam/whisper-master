"""Load and validate evaluation cases in the generalized schema.

A case: id, category, input ({text} or {audio}), optional reference and
asr_reference, targets (LLM modes to run), must_contain/must_not_contain, note.
Legacy rows (a bare string `input`, no `targets`) are normalized on load so the
existing 84 cases keep working.
"""
import json

DEFAULT_TARGETS = ["light", "polish"]


def normalize_case(raw: dict) -> dict:
    inp = raw.get("input")
    if isinstance(inp, str):
        inp = {"text": inp}
    if not isinstance(inp, dict) or not ({"text", "audio"} & set(inp)):
        raise ValueError(f"case {raw.get('id')}: input must be {{text}} or {{audio}}")
    if "audio" in inp and not raw.get("asr_reference"):
        raise ValueError(f"case {raw.get('id')}: audio case needs asr_reference")
    return {
        "id": raw["id"],
        "category": raw.get("category", "uncategorized"),
        "input": inp,
        "reference": raw.get("reference"),
        "asr_reference": raw.get("asr_reference"),
        "targets": raw.get("targets", list(DEFAULT_TARGETS)),
        "must_contain": raw.get("must_contain", []),
        "must_not_contain": raw.get("must_not_contain", []),
        "note": raw.get("note", ""),
    }


def load_cases(path: str) -> list:
    cases = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                cases.append(normalize_case(json.loads(line)))
    return cases
