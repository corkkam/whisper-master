"""crew route: the deterministic router (spec 6.3)."""
from __future__ import annotations

import fcntl
import json
import os
import re
import sys
import tempfile

from crew import config

TYPES = ("code", "qa", "copy", "design", "research", "docs", "ops")
ADVISER_ROLES = ("pm", "qa", "design", "marketing", "user", "architect", "custom")
DEFAULT_PRIORITY = ["pm", "user", "design", "marketing", "qa", "architect"]
DEFAULT_TAGS = ["data-format", "public-api", "privacy", "security", "user-facing",
                "pricing", "release", "irreversible", "launch"]
DEFAULT_OWNER_TAGS = ["privacy", "security", "pricing", "release", "irreversible"]
TASK_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def _tag_order(cfg: dict) -> list:
    return list((cfg.get("gates") or {}).get("tags") or DEFAULT_TAGS)


def _sort_tags(tags, order: list) -> list:
    return sorted(set(tags), key=lambda t: (order.index(t) if t in order else len(order), t))


def _any_match(paths: list, patterns: list) -> bool:
    return any(config.path_matches(p, pat) for p in paths for pat in patterns)


def _rule_text(i: int, rule: dict) -> str:
    when = rule.get("when") or {}
    conds = []
    if when.get("type"):
        conds.append("type " + when["type"])
    if when.get("paths"):
        conds.append("paths")
    if when.get("tags_any"):
        conds.append("tags " + "/".join(when["tags_any"]))
    parts = []
    if rule.get("assign"):
        parts.append("assign " + rule["assign"])
    if rule.get("consult"):
        parts.append("consult " + ",".join(rule["consult"]))
    if rule.get("gates"):
        parts.append("gates " + ",".join(rule["gates"]))
    return "rule %d: %s -> %s" % (i, ", ".join(conds) or "any", ", ".join(parts) or "no action")


def route(cfg: dict, type_: str, paths: list, tags: list) -> dict:
    gates = cfg.get("gates") or {}
    huddle_cfg = cfg.get("huddle") or {}
    order = _tag_order(cfg)
    agents = cfg.get("agents") or []
    lead = cfg.get("lead")
    paths = list(paths or [])
    tags = list(tags or [])

    # Step 1
    if type_ not in TYPES:
        raise ValueError("invalid type %r, expected one of %s" % (type_, ", ".join(TYPES)))
    for t in tags:
        if t not in order:
            raise ValueError("invalid tag %r, expected one of %s" % (t, ", ".join(order)))
    if not all(isinstance(p, str) and p for p in paths):
        raise ValueError("paths must be non-empty strings")

    reason = []
    # Step 2
    components = [a for a in agents if a.get("role") == "component"
                  and _any_match(paths, a.get("paths") or [])]
    # Step 3
    gate_tags = set(tags)
    for rule in gates.get("rules") or []:
        if rule.get("tag") and _any_match(paths, rule.get("paths") or []):
            if rule["tag"] not in gate_tags:
                reason.append("gate rule: %s from path" % rule["tag"])
            gate_tags.add(rule["tag"])
    # Step 4: rules are tested once, with the step 3 tags
    matched = []
    for i, rule in enumerate(cfg.get("routing") or []):
        when = rule.get("when") or {}
        if "type" in when and when["type"] != type_:
            continue
        if "paths" in when and not _any_match(paths, when["paths"] or []):
            continue
        if "tags_any" in when and not (set(when["tags_any"] or []) & gate_tags):
            continue
        matched.append(rule)
        reason.append(_rule_text(i, rule))
    for rule in matched:
        gate_tags.update(rule.get("gates") or [])
    gate_tags = _sort_tags(gate_tags, order)
    # Step 5
    assignees = None
    for rule in matched:
        if rule.get("assign"):
            assignees = [rule["assign"]]
            break
    if assignees is None:
        assignees = [a["id"] for a in components] or [lead]
        if components:
            reason.append("assignee from component paths: " + ", ".join(assignees))
    # Step 6
    subjects = [a["id"] for a in components]
    max_subjects = huddle_cfg.get("max_subjects", 3)
    split_required = len(subjects) > max_subjects
    if split_required:
        reason.append("split required: %d components, limit %d" % (len(subjects), max_subjects))
    # Step 7
    excluded = set(assignees) | set(subjects) | {lead}
    forced = []
    for rule in matched:
        for aid in rule.get("consult") or []:
            if aid not in forced and aid not in excluded:
                forced.append(aid)
    # Step 8
    huddle = bool(gate_tags) or bool(forced)
    # Step 9
    skip = excluded | set(forced)
    candidates = [a["id"] for a in agents
                  if a.get("role") in ADVISER_ROLES and a["id"] not in skip
                  and set(a.get("consult_on") or []) & set(gate_tags)]
    # Step 10
    priority = huddle_cfg.get("priority") or DEFAULT_PRIORITY
    candidates.sort(key=lambda i: (priority.index(i) if i in priority else len(priority), i))
    if candidates:
        reason.append("consult_on matched: " + ", ".join(candidates))
    # Step 11
    max_advisers = huddle_cfg.get("max_advisers", 3)
    both = forced + candidates
    advisers, skipped = both[:max_advisers], both[max_advisers:]
    if len(forced) > max_advisers:
        reason.append("consult capped")
    if skipped:
        reason.append("advisers skipped over the limit of %d: %s" % (max_advisers, ", ".join(skipped)))
    # Step 12
    owner_tags = huddle_cfg.get("owner_tags", DEFAULT_OWNER_TAGS)
    owner_gate = bool(set(gate_tags) & set(owner_tags))

    return {"type": type_, "assignees": assignees, "subjects": subjects, "gate_tags": gate_tags,
            "forced": forced, "advisers": advisers, "skipped": skipped, "huddle": huddle,
            "split_required": split_required, "owner_gate": owner_gate, "reason": reason}


def save_part(project: str, task_id: str, part: int, out: dict) -> dict:
    """Step 14: merge one part into .crew/tasks/<task>/route.json."""
    if not TASK_ID_RE.match(str(task_id)):
        raise ValueError("invalid task id %r" % (task_id,))
    if not isinstance(part, int) or part < 1:
        raise ValueError("part must be an integer of 1 or more")
    d = os.path.join(project, ".crew", "tasks", task_id)
    path = os.path.join(d, "route.json")
    os.makedirs(d, exist_ok=True)
    # One lock per task folder: two parts saved at once must not lose a part.
    with open(os.path.join(d, "route.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        doc = None
        try:
            with open(path, encoding="utf-8") as f:
                doc = json.load(f)
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as e:
            raise ValueError("route.json is corrupt (%s): fix or delete %s" % (e, path))
        if doc is not None and (not isinstance(doc, dict) or not isinstance(doc.get("parts"), dict)):
            raise ValueError("route.json is corrupt (no parts object): fix or delete %s" % path)
        if doc is None:
            doc = {"task_id": task_id, "gate_tags": [], "owner_gate": False, "parts": {}}
        doc["parts"][str(part)] = out
        cfg, _ = config.load(project)
        doc["gate_tags"] = _sort_tags({t for p in doc["parts"].values() for t in p.get("gate_tags", [])},
                                      _tag_order(cfg))
        doc["owner_gate"] = any(p.get("owner_gate") for p in doc["parts"].values())
        fd, tmp = tempfile.mkstemp(dir=d, prefix="route.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(doc, f, indent=2)
                f.write("\n")
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    return doc


def _split(value) -> list:
    return [x.strip() for x in (value or "").split(",") if x.strip()]


def _fmt(value) -> str:
    if isinstance(value, str):
        return value
    return json.dumps(value)


def _norm_paths(project: str, paths: list) -> list:
    """Spec 6.1: each path relative to the project root, with no ./, .., or worktree part."""
    out = []
    for p in paths:
        rel, _wt = config.rel_path(project, p, project)
        if rel is None:
            raise ValueError("path %s is outside the project" % p)
        # Keep a trailing slash: a folder rule such as 'src/auth/' still matches it.
        out.append(rel + "/" if p.endswith("/") and rel != "." else rel)
    return out


def run_route(args) -> int:
    project = config.find_project(os.getcwd())
    if project is None:
        print("crew route: not inside a crew project", file=sys.stderr)
        return 8
    cfg, errors = config.load(project)
    if errors or not cfg:
        print("crew route: bad crew.json: %s" % "; ".join(errors), file=sys.stderr)
        return 2
    try:
        part = getattr(args, "part", None)
        task = getattr(args, "task", None)
        if part is not None and (not isinstance(part, int) or part < 1):
            raise ValueError("part must be an integer of 1 or more")
        if task is not None and not task:
            raise ValueError("--task must not be empty")
        out = route(cfg, getattr(args, "type", None), _norm_paths(project, _split(getattr(args, "paths", ""))),
                    _split(getattr(args, "tags", "")))
        if task:
            save_part(project, task, 1 if part is None else part, out)
    except ValueError as e:
        print("crew route: %s" % e, file=sys.stderr)
        return 2
    except (TypeError, AttributeError, KeyError) as e:
        print("crew route: bad crew.json: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 2
    if getattr(args, "json", False):
        print(json.dumps(out))
    else:
        for k, v in out.items():
            print("%s: %s" % (k, _fmt(v)))
    return 0
