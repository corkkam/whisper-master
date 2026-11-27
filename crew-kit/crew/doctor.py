"""crew doctor: the MVP lint checks (spec 8.3)."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta

from crew import config

ROLES = ("lead", "pm", "qa", "design", "marketing", "user", "architect", "component", "helper", "custom")
FRONT_KEYS = ("name", "description", "tools", "model", "effort", "memory", "maxTurns", "skills", "color")
EFFORTS = ("low", "medium", "high", "xhigh", "max")
ID_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
INTERFACE_KEYS = ("component", "owner", "interface_version", "last_verified", "verified_by")
DENY_WORDS = ["revenue", "invoice", "pricing model", "growth strategy", "go-to-market", "customer list"]
GITIGNORE_LINES = ["ledger.jsonl", "ledger.lock", "STOP", "tasks/", "inbox/", "*.tmp"]
PHASE2 = ("D05", "D07", "D08", "D09", "D14", "D15", "D16")
MVP = ("D01", "D02", "D03", "D04", "D06", "D10", "D11", "D12", "D13", "D17", "D18", "D19", "D20",
       "D21", "D22", "D23", "D24")
HOOK = '"$HOME"/.crew/bin/crew hook '
# event -> list of (hook name, async expected)
HOOKS = {
    "SessionStart": [("session-start", False), ("event", True)],
    "SubagentStart": [("session-start", False), ("event", True)],
    "UserPromptSubmit": [("session-start", False), ("event", True)],
    "PreToolUse": [("guard", False), ("event", True)],
    "PostToolUse": [("event", True)],
    "PostToolUseFailure": [("event", True)],
    "PermissionRequest": [("event", True)],
    "Notification": [("event", True)],
    "SubagentStop": [("event", False)],
    "Stop": [("event", False)],
    "StopFailure": [("event", True)],
    "SessionEnd": [("event", False)],
}
# Known keys, for the unknown-key warning. Both window key spellings are accepted
# (build notes override the spec names).
TOP_KEYS = {"version", "project", "lead", "agents", "gates", "routing", "huddle", "budget", "autonomy",
            "guard", "eval", "doctor", "context"}
AGENT_KEYS = {"id", "role", "name", "model", "effort", "engine", "consult_on", "paths", "component_dir",
              "max_budget_usd", "hue"}
SUB_KEYS = {
    "project": {"name", "public_paths"},
    "gates": {"tags", "rules"},
    "huddle": {"max_advisers", "max_subjects", "priority", "max_words", "hard_block_tags", "owner_tags"},
    "budget": {"per_task_usd", "per_day_usd", "per_loop_usd", "call_reserve_usd", "cap_headroom",
               "five_hour_max_pct", "seven_day_max_pct", "max_five_hour_pct", "max_seven_day_pct",
               "snapshot_max_age_s", "snapshot_max_age_auto_s", "allow_unknown_window",
               "overage_guard_verified", "account", "max_budget_usd"},
    "autonomy": {"level", "set_at", "expires_at", "set_by"},
    "guard": {"protected", "deny_bash"},
    "eval": {"commands", "timeout_s"},
    "doctor": {"deny_words", "interface_max_age_days"},
    "context": {"max_turns"},
}
BUDGET_NUMBERS = ("per_task_usd", "per_day_usd", "per_loop_usd", "snapshot_max_age_s", "snapshot_max_age_auto_s")
WINDOW_KEYS = ("five_hour_max_pct", "seven_day_max_pct", "max_five_hour_pct", "max_seven_day_pct")
DEFAULT_MAX_BUDGET = {"lead": 3.0, "component": 2.0}
DEFAULT_MODEL = {"lead": "opus", "helper": "haiku"}


def _e(level, path, text):
    return (level, path, text)


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return None


def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def front_matter(text):
    """Return (dict, error). Handles `key: value` and `key:` followed by `  - item` lines."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None, "no front matter"
    out, key = {}, None
    for line in lines[1:]:
        if line.strip() == "---":
            return out, None
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
        if m:
            key = m.group(1)
            if key in out:
                return None, "front matter key %s appears twice" % key
            out[key] = m.group(2).strip()
            if out[key] == "":
                out[key] = []
        elif re.match(r"^\s+-\s+", line) and key and isinstance(out.get(key), list):
            out[key].append(line.split("-", 1)[1].strip())
        elif line.strip() and not line.lstrip().startswith("#"):
            return None, "front matter line does not parse: %r" % line
    return None, "front matter is not closed"


# ---- checks: each takes a context and returns a list of (level, path, text) ----

class Ctx:
    def __init__(self, project, raw, cfg):
        self.project, self.raw, self.cfg = project, raw, cfg
        self.agents = [a for a in (cfg.get("agents") or []) if isinstance(a, dict)]
        self.components = [a for a in self.agents if a.get("role") == "component"]
        self.public = (cfg.get("project") or {}).get("public_paths") or []
        dw = (cfg.get("doctor") or {}).get("deny_words")
        # A configured list wins, also an empty one (no words). Only a missing key uses the default.
        self.deny = DENY_WORDS if dw is None else dw

    def p(self, rel):
        return os.path.join(self.project, rel)


def _strs(v):
    return isinstance(v, list) and all(isinstance(x, str) for x in v)


def _d01_types(raw):
    """Type checks for the nested keys that route and doctor read (spec 4)."""
    out = []

    def bad(msg):
        out.append(_e("error", ".crew/crew.json", msg))

    def sect(k):
        v = raw.get(k)
        return v if isinstance(v, dict) else {}

    h = sect("huddle")
    for k in ("max_advisers", "max_subjects", "max_words"):
        if k in h and not (isinstance(h[k], int) and not isinstance(h[k], bool)):
            bad("huddle.%s must be an integer" % k)
    for k in ("priority", "hard_block_tags", "owner_tags"):
        if k in h and not _strs(h[k]):
            bad("huddle.%s must be a list of strings" % k)
    g = sect("gates")
    if "tags" in g and not _strs(g["tags"]):
        bad("gates.tags must be a list of strings")
    if "rules" in g:
        rules = g["rules"]
        if not (isinstance(rules, list) and all(isinstance(r, dict) and isinstance(r.get("tag"), str)
                                                 and _strs(r.get("paths")) for r in rules)):
            bad("gates.rules must be a list of {tag: string, paths: list of strings}")
    if isinstance(raw.get("routing"), list):
        for i, r in enumerate(raw["routing"]):
            if not isinstance(r, dict):
                bad("routing[%d] must be an object" % i)
                continue
            if not isinstance(r.get("when", {}), dict):
                bad("routing[%d].when must be an object" % i)
            if "assign" in r and not isinstance(r["assign"], str):
                bad("routing[%d].assign must be a string" % i)
            for k in ("consult", "gates"):
                if k in r and not _strs(r[k]):
                    bad("routing[%d].%s must be a list of strings" % (i, k))
            w = r.get("when")
            if isinstance(w, dict):
                if "type" in w and not isinstance(w["type"], str):
                    bad("routing[%d].when.type must be a string" % i)
                for k in ("paths", "tags_any"):
                    if k in w and not _strs(w[k]):
                        bad("routing[%d].when.%s must be a list of strings" % (i, k))
    if isinstance(raw.get("project"), dict) and "public_paths" in raw["project"] \
            and not _strs(raw["project"]["public_paths"]):
        bad("project.public_paths must be a list of strings")
    if "deny_words" in sect("doctor") and not _strs(raw["doctor"]["deny_words"]):
        bad("doctor.deny_words must be a list of strings")
    if isinstance(raw.get("agents"), list):
        for a in raw["agents"]:
            if isinstance(a, dict) and "component_dir" in a and not isinstance(a["component_dir"], str):
                bad("agent %s: component_dir must be a string" % a.get("id"))
    au = sect("autonomy")
    for k in ("set_at", "expires_at"):
        if k in au and au[k] is not None and not isinstance(au[k], str):
            bad("autonomy.%s must be a string or null" % k)
    return out


def d01(raw, cfg_errors):
    out = []
    if raw.get("version") != 1:
        out.append(_e("error", ".crew/crew.json", "version must be 1"))
    proj = raw.get("project")
    if not isinstance(proj, dict) or not isinstance(proj.get("name"), str) or not proj.get("name"):
        out.append(_e("error", ".crew/crew.json", "project.name is required"))
    elif not isinstance(proj.get("public_paths", []), list):
        out.append(_e("error", ".crew/crew.json", "project.public_paths must be a list"))
    if not isinstance(raw.get("lead"), str):
        out.append(_e("error", ".crew/crew.json", "lead must be a string"))
    agents = raw.get("agents")
    if not isinstance(agents, list) or not agents:
        out.append(_e("error", ".crew/crew.json", "agents must be a non-empty list"))
        agents = []
    for i, a in enumerate(agents):
        if not isinstance(a, dict):
            out.append(_e("error", ".crew/crew.json", "agents[%d] must be an object" % i))
            continue
        label = "agent %s" % a.get("id", i)
        if not isinstance(a.get("id"), str):
            out.append(_e("error", ".crew/crew.json", "agents[%d].id must be a string" % i))
        if a.get("role") not in ROLES:
            out.append(_e("error", ".crew/crew.json", "%s: role must be one of %s" % (label, ", ".join(ROLES))))
        for k in ("consult_on", "paths"):
            if k in a and not (isinstance(a[k], list) and all(isinstance(x, str) for x in a[k])):
                out.append(_e("error", ".crew/crew.json", "%s: %s must be a list of strings" % (label, k)))
        if a.get("role") == "component" and not a.get("paths"):
            out.append(_e("error", ".crew/crew.json", "%s: component needs paths" % label))
        if "effort" in a and a["effort"] not in EFFORTS:
            out.append(_e("error", ".crew/crew.json", "%s: effort must be one of %s" % (label, ", ".join(EFFORTS))))
        if "name" in a and not (isinstance(a["name"], str) and 1 <= len(a["name"]) <= 24):
            out.append(_e("error", ".crew/crew.json", "%s: name must be 1 to 24 characters" % label))
        for k in sorted(set(a) - AGENT_KEYS):
            out.append(_e("warn", ".crew/crew.json", "%s: unknown key %s" % (label, k)))
    for k, typ in (("gates", dict), ("routing", list), ("huddle", dict), ("budget", dict),
                   ("autonomy", dict), ("guard", dict), ("eval", dict), ("doctor", dict), ("context", dict)):
        if k in raw and not isinstance(raw[k], typ):
            out.append(_e("error", ".crew/crew.json", "%s must be a %s" % (k, "list" if typ is list else "object")))
    if isinstance(raw.get("autonomy"), dict) and "set_at" not in raw["autonomy"]:
        out.append(_e("error", ".crew/crew.json", "autonomy.set_at is required"))
    out += _d01_types(raw)
    for k in sorted(set(raw) - TOP_KEYS):
        out.append(_e("warn", ".crew/crew.json", "unknown key %s" % k))
    for k, known in SUB_KEYS.items():
        if isinstance(raw.get(k), dict):
            for u in sorted(set(raw[k]) - known):
                out.append(_e("warn", ".crew/crew.json", "unknown key %s.%s" % (k, u)))
    return out


def d02(c):
    out, seen = [], set()
    for a in c.agents:
        i = a.get("id")
        if not isinstance(i, str) or not ID_RE.match(i):
            out.append(_e("error", ".crew/crew.json", "agent id %r does not match %s" % (i, ID_RE.pattern)))
        elif i in seen:
            out.append(_e("error", ".crew/crew.json", "agent id %s is not unique" % i))
        seen.add(i)
    leads = [a.get("id") for a in c.agents if a.get("role") == "lead"]
    if len(leads) != 1:
        out.append(_e("error", ".crew/crew.json", "expected exactly one lead role, found %d" % len(leads)))
    elif leads[0] != c.cfg.get("lead"):
        out.append(_e("error", ".crew/crew.json", "lead is %r but the lead-role agent is %r" % (c.cfg.get("lead"), leads[0])))
    return out


def _agent_front(c, a):
    rel = ".claude/agents/%s.md" % a.get("id")
    text = _read(c.p(rel))
    if text is None:
        return rel, None, "agent file is missing"
    fm, err = front_matter(text)
    return rel, fm, err


def d03(c):
    out = []
    for a in c.agents:
        rel, fm, err = _agent_front(c, a)
        if fm is None:
            out.append(_e("error", rel, err))
            continue
        if fm.get("name") != a.get("id"):
            out.append(_e("error", rel, "name %r must equal the agent id %r" % (fm.get("name"), a.get("id"))))
        if not fm.get("description"):
            out.append(_e("error", rel, "description is missing"))
        for k in fm:
            if k not in FRONT_KEYS:
                out.append(_e("error", rel, "front matter key %s is not documented" % k))
    return out


def d04(c):
    out = []
    for a in c.agents:
        rel, fm, err = _agent_front(c, a)
        if fm is not None and fm.get("memory") != "project":
            out.append(_e("error", rel, "memory must be project"))
    return out


def d06(c):
    out = []
    for a in c.components:
        d = a.get("component_dir")
        if not d:
            out.append(_e("error", a.get("id", "?"), "component has no component_dir"))
            continue
        rel = os.path.join(d, "INTERFACE.md")
        raw = _read(c.p(rel))
        if raw is None:
            out.append(_e("error", rel, "INTERFACE.md is missing"))
            continue
        fm, err = front_matter(raw)
        if fm is None:
            out.append(_e("error", rel, err))
        else:
            for k in INTERFACE_KEYS:
                if k not in fm:
                    out.append(_e("error", rel, "front matter key %s is missing" % k))
        if not re.search(r"^## Architecture\s*$", raw, re.M):
            out.append(_e("error", rel, "## Architecture heading is missing"))
        nbytes, nlines = len(raw.encode("utf-8")), len(raw.splitlines())
        if nlines > 150 or nbytes > 5120:
            out.append(_e("error", rel, "%d lines and %d bytes, limit 150 lines and 5120 bytes" % (nlines, nbytes)))
    return out


def d10(c):
    text = _read(c.p("AGENTS.md"))
    if text is None:
        return [_e("error", "AGENTS.md", "AGENTS.md is missing")]
    m = re.search(r"<!-- crew:begin -->(.*?)<!-- crew:end -->", text, re.S)
    if not m:
        return [_e("error", "AGENTS.md", "crew block is missing (markers crew:begin and crew:end)")]
    block, out = m.group(0), []
    if len(block.splitlines()) > 60:
        out.append(_e("error", "AGENTS.md", "crew block has %d lines, limit 60" % len(block.splitlines())))
    for a in c.agents:
        i = a.get("id")
        if isinstance(i, str) and not re.search(r"(?<![A-Za-z0-9-])%s(?![A-Za-z0-9-])" % re.escape(i), block):
            out.append(_e("error", "AGENTS.md", "crew block does not list agent %s" % i))
    return out


def d11(c):
    rel = ".claude/settings.json"
    text = _read(c.p(rel))
    if text is None:
        return [_e("error", rel, "settings.json is missing")]
    try:
        hooks = (json.loads(text) or {}).get("hooks") or {}
    except ValueError as e:
        return [_e("error", rel, "invalid JSON: %s" % e)]
    out = []
    if not isinstance(hooks, dict):
        return [_e("error", rel, "hooks must be an object")]
    for event, wanted in HOOKS.items():
        found, matchers = {}, {}
        for group in hooks.get(event) or []:
            for h in (group.get("hooks") or []) if isinstance(group, dict) else []:
                if isinstance(h, dict) and h.get("type") == "command":
                    found.setdefault(h.get("command"), h)
                    matchers.setdefault(h.get("command"), group.get("matcher"))
        for name, want_async in wanted:
            h = found.get(HOOK + name)
            if h is None:
                out.append(_e("error", rel, "%s has no hook command %s%s" % (event, HOOK, name)))
                continue
            if bool(h.get("async")) != want_async:
                out.append(_e("error", rel, "%s %s must have async %s" % (event, name, str(want_async).lower())))
            if name == "guard":
                # The guard must see Edit and Write too, so its group must match every tool.
                if matchers.get(HOOK + name) not in (None, "", "*"):
                    out.append(_e("error", rel, "PreToolUse guard matcher must be * (or empty), not %r"
                                  % (matchers[HOOK + name],)))
                # Build notes: the snippet has no onFailure. "block" makes a shim crash block the owner.
                of = h.get("onFailure")
                if of == "block":
                    out.append(_e("warn", rel, "PreToolUse guard onFailure block stops the owner's sessions if the shim crashes"))
                elif of is not None:
                    out.append(_e("error", rel, "PreToolUse guard onFailure must be unset (or block), not %r" % (of,)))
    return out


def d12(c):
    path = os.path.join(config.crew_home(), "bin", "crew")
    from crew import __version__
    if not os.path.isfile(path) or not os.access(path, os.X_OK):
        return [_e("error", path, "crew shim is missing or not executable, run crew install")]
    try:
        r = subprocess.run([path, "--version"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=5)
    except subprocess.TimeoutExpired:
        return [_e("error", path, "crew --version timed out after 5 s")]
    except OSError as e:
        return [_e("error", path, "crew --version did not run: %s" % e)]
    got = r.stdout.strip()
    if r.returncode != 0:
        return [_e("error", path, "crew --version exited %d" % r.returncode)]
    if got != "crew %s" % __version__:
        return [_e("error", path, "version is %r, this kit is %r" % (got, "crew %s" % __version__))]
    return []


def _git(repo, *args):
    try:
        r = subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=30,
                           env=dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0"))
        return r.returncode, r.stdout
    except (OSError, subprocess.SubprocessError):
        return 127, ""


def d13(c):
    rel = ".crew/.gitignore"
    out = []
    rc, _ = _git(c.project, "check-ignore", "-q", ".crew/ledger.jsonl")
    if rc != 0:
        out.append(_e("error", ".crew/ledger.jsonl", "git does not ignore the ledger (check-ignore exit %d)" % rc))
    text = _read(c.p(rel))
    lines = [x.strip() for x in (text or "").splitlines()]
    missing = [x for x in GITIGNORE_LINES if x not in lines]
    if text is None:
        out.append(_e("error", rel, ".crew/.gitignore is missing"))
    elif missing:
        out.append(_e("error", rel, "missing lines: %s" % ", ".join(missing)))
    return out


def _find_deny(text, words):
    low = text.lower()
    return [w for w in words if w.lower() in low]


def _is_public(c, rel):
    return any(config.path_matches(rel, pat) for pat in c.public)


def d17(c):
    files = []
    for a in c.components:
        d = a.get("component_dir")
        if d:
            for name in ("INTERFACE.md", "DECISIONS.md"):
                files.append(os.path.join(d, name))
    mem = ".claude/agent-memory"
    roots = [mem] if _is_public(c, mem + "/x") else []
    for pat in c.public:
        if pat.endswith("/") and not pat.startswith("**/"):
            roots.append(os.path.join(pat.rstrip("/"), mem))
    for root in roots:
        for dp, _, fns in os.walk(c.p(root)):
            files += [os.path.relpath(os.path.join(dp, f), c.project) for f in fns if f.endswith(".md")]
    out = []
    for rel in sorted(set(files)):
        if not _is_public(c, rel):
            continue
        text = _read(c.p(rel))
        for w in _find_deny(text or "", c.deny):
            out.append(_e("error", rel, "deny word %r in a file under a public path" % w))
    return out


def _iso(s):
    return datetime.fromisoformat(s[:-1] + "+00:00" if s.endswith("Z") else s)


def d18(c):
    a = c.cfg.get("autonomy") or {}
    level, rel = a.get("level", "L3"), ".crew/crew.json"
    if level not in ("L0", "L1", "L2", "L3", "L4", "L5"):
        return [_e("error", rel, "autonomy.level %r must be L0 to L5" % (level,))]
    if level not in ("L4", "L5"):
        return []
    if not a.get("expires_at"):
        return [_e("error", rel, "autonomy %s needs expires_at" % level)]
    try:
        set_at, exp = _iso(a["set_at"]), _iso(a["expires_at"])
        if set_at.tzinfo is None or exp.tzinfo is None:
            return [_e("error", rel, "autonomy set_at and expires_at need a time zone offset")]
        days = 30 if level == "L4" else 7
        if exp > set_at + timedelta(days=days):
            return [_e("error", rel, "autonomy %s expires_at is more than %d days after set_at" % (level, days))]
    except (KeyError, ValueError, TypeError, AttributeError):
        return [_e("error", rel, "autonomy set_at or expires_at is not a valid ISO 8601 time with offset")]
    return []


def d19(c):
    b, rel, out = c.cfg.get("budget") or {}, ".crew/crew.json", []
    for k in BUDGET_NUMBERS:
        if k in b and not (_num(b[k]) and b[k] > 0):
            out.append(_e("error", rel, "budget.%s must be a number above 0" % k))
    if _num(b.get("per_task_usd")) and _num(b.get("per_day_usd")) and b["per_task_usd"] > b["per_day_usd"]:
        out.append(_e("error", rel, "budget.per_task_usd is above per_day_usd"))
    for k in WINDOW_KEYS:
        if k in b and not (_num(b[k]) and 0 <= b[k] <= 100):
            out.append(_e("error", rel, "budget.%s must be 0 to 100" % k))
    if "cap_headroom" in b and not (_num(b["cap_headroom"]) and 0 < b["cap_headroom"] <= 1):
        out.append(_e("error", rel, "budget.cap_headroom must be above 0 and at most 1"))
    caps = {}  # model -> smallest cap among the agents that run on it
    reserve = b.get("call_reserve_usd") or {}
    for a in c.agents:
        v = a.get("max_budget_usd", DEFAULT_MAX_BUDGET.get(a.get("role"), 0.5))
        if not (_num(v) and v > 0):
            out.append(_e("error", rel, "agent %s max_budget_usd must be above 0" % a.get("id")))
            continue
        m = a.get("model") or DEFAULT_MODEL.get(a.get("role"), "sonnet")
        key = m if m in reserve else "default"
        caps[key] = min(v, caps.get(key, v))
    if isinstance(reserve, dict):
        # The reserve of a model must stay below the cap of every agent that uses it.
        for k, v in reserve.items():
            if not (_num(v) and v > 0 and (k not in caps or v < caps[k])):
                out.append(_e("error", rel, "budget.call_reserve_usd.%s must be above 0 and below the smallest agent cap%s"
                              % (k, " (%s)" % caps[k] if k in caps else "")))
    return out


def d20(c):
    ids = {a.get("id") for a in c.agents}
    tags = set((c.cfg.get("gates") or {}).get("tags") or [])
    types = ("code", "qa", "copy", "design", "research", "docs", "ops")
    rel, out = ".crew/crew.json", []
    # Raw values: a default priority list must not fail a small roster.
    raw = c.raw
    for i, r in enumerate(raw.get("routing") or []):
        if not isinstance(r, dict):
            out.append(_e("error", rel, "routing[%d] must be an object" % i))
            continue
        for aid in ([r["assign"]] if r.get("assign") else []) + list(r.get("consult") or []):
            if aid not in ids:
                out.append(_e("error", rel, "routing[%d] names unknown agent %s" % (i, aid)))
        for t in list(r.get("gates") or []) + list((r.get("when") or {}).get("tags_any") or []):
            if t not in tags:
                out.append(_e("error", rel, "routing[%d] names unknown tag %s" % (i, t)))
        wt = (r.get("when") or {}).get("type")
        if wt is not None and wt not in types:
            out.append(_e("error", rel, "routing[%d] has unknown type %s" % (i, wt)))
    h = raw.get("huddle") or {}
    for aid in h.get("priority") or []:
        if aid not in ids:
            out.append(_e("error", rel, "huddle.priority names unknown agent %s" % aid))
    for k in ("owner_tags", "hard_block_tags"):
        for t in h.get(k) or []:
            if t not in tags:
                out.append(_e("error", rel, "huddle.%s names unknown tag %s" % (k, t)))
    for r in (raw.get("gates") or {}).get("rules") or []:
        if isinstance(r, dict) and r.get("tag") not in tags:
            out.append(_e("error", rel, "gates.rules names unknown tag %s" % r.get("tag")))
    for a in c.agents:
        for t in a.get("consult_on") or []:
            if t not in tags:
                out.append(_e("error", rel, "agent %s consult_on names unknown tag %s" % (a.get("id"), t)))
    return out


def d21(c):
    return [_e("error", ".crew/crew.json", "agent %s: engine %r is not supported, use claude" % (a.get("id"), a.get("engine")))
            for a in c.agents if a.get("engine", "claude") != "claude"]


def d22(c):
    text = _read(c.p("ARCHITECTURE.md"))
    if text is None:
        return [_e("warn", "ARCHITECTURE.md", "ARCHITECTURE.md is missing")]
    n, b = len(text.splitlines()), len(text.encode("utf-8"))
    if n > 400 or b > 16384:
        return [_e("warn", "ARCHITECTURE.md", "%d lines and %d bytes, limit 400 lines and 16 KiB" % (n, b))]
    return []


def _toplevel(path):
    if not os.path.isdir(path):
        return None
    rc, out = _git(path, "rev-parse", "--show-toplevel")
    return os.path.realpath(out.strip()) if rc == 0 and out.strip() else None


def _public_dirs(c):
    for pat in c.public:
        if pat.startswith("**/") or any(ch in pat for ch in "*?["):
            continue  # shortcut: only plain folder prefixes are mapped to a repo
        yield pat.rstrip("/")


def _repos(c, public_only):
    seen, out = set(), []
    starts = [] if public_only else [c.project]
    starts += [c.p(d) for d in _public_dirs(c)]
    for s in starts:
        top = _toplevel(s)
        if top and top not in seen:
            seen.add(top)
            out.append(top)
    return out


def _base(repo):
    rc, out = _git(repo, "symbolic-ref", "-q", "refs/remotes/origin/HEAD")
    if rc == 0 and out.strip():
        ref = out.strip().replace("refs/remotes/", "", 1)
        if _git(repo, "rev-parse", "--verify", "-q", ref)[0] == 0:
            return ref
    for b in ("dev", "main"):
        if _git(repo, "rev-parse", "--verify", "-q", "refs/heads/" + b)[0] == 0:
            return b
    return None


def d23(c):
    out, changed = [], set()
    repos = _repos(c, False)
    if not repos:
        return []
    for repo in repos:
        base = _base(repo)
        if base is None:
            continue
        rc, text = _git(repo, "diff", base + "...HEAD", "--name-only")
        if rc != 0:
            out.append(_e("warn", repo, "git diff against %s failed (exit %d)" % (base, rc)))
            continue
        for name in text.splitlines():
            rel = os.path.relpath(os.path.join(repo, name), os.path.realpath(c.project))
            if not rel.startswith(".."):
                changed.add(rel.replace(os.sep, "/"))
    for a in c.components:
        d = a.get("component_dir")
        if not d:
            continue
        docs = {os.path.normpath(os.path.join(d, n)).replace(os.sep, "/") for n in ("INTERFACE.md", "DECISIONS.md")}
        hit = any(config.path_matches(p, pat) for p in changed for pat in a.get("paths") or [])
        if hit and not (changed & docs):
            out.append(_e("warn", d, "%s: code changed but INTERFACE.md and DECISIONS.md did not" % a.get("id")))
    return out


def d24(c):
    out = []
    for repo in _repos(c, True):
        rc, branch = _git(repo, "rev-parse", "--abbrev-ref", "HEAD")
        texts = [("branch name", branch.strip())] if rc == 0 else []
        base = _base(repo)
        if base:
            rc, log = _git(repo, "log", base + "..HEAD", "--format=%h%x1f%s%n%b%x1e")
            if rc != 0:
                out.append(_e("warn", repo, "git log against %s failed (exit %d)" % (base, rc)))
            else:
                for rec in log.split("\x1e"):
                    if rec.strip():
                        sha, _, msg = rec.strip().partition("\x1f")
                        texts.append(("commit " + sha, msg))
        for what, t in texts:
            for w in _find_deny(t, c.deny):
                out.append(_e("error", repo, "deny word %r in %s" % (w, what)))
    return out


CHECKS = {"D02": d02, "D03": d03, "D04": d04, "D06": d06, "D10": d10, "D11": d11, "D12": d12,
          "D13": d13, "D17": d17, "D18": d18, "D19": d19, "D20": d20, "D21": d21, "D22": d22,
          "D23": d23, "D24": d24}


def _entries(cid, results, ok_path):
    if not results:
        return [{"id": cid, "level": "ok", "path": ok_path, "text": "ok"}]
    return [{"id": cid, "level": lv, "path": p, "text": t} for lv, p, t in results]


def _safe(cid, c):
    """Run one check. An exception becomes an error, so doctor exits 0 or 7 and never crashes."""
    try:
        return CHECKS[cid](c)
    except Exception as e:  # shortcut: broad catch on purpose, any bad input must give a finding
        return [_e("error", ".crew/crew.json", "%s: check failed: %s" % (cid, type(e).__name__))]


def check(project: str, *, changed_only: bool = False) -> list:
    raw, problem = None, None
    text = _read(os.path.join(project, ".crew", "crew.json"))
    if text is None:
        problem = "crew.json is missing"
    else:
        try:
            raw = json.loads(text)
            if not isinstance(raw, dict):
                problem, raw = "crew.json must be a JSON object", None
        except ValueError as e:
            problem = "crew.json is not valid JSON: %s" % e
    cfg, cfg_errors = ({}, [])
    if raw is not None:
        try:
            d1 = d01(raw, [])
        except Exception as e:
            d1 = [_e("error", ".crew/crew.json", "D01: check failed: %s" % type(e).__name__)]
        cfg, cfg_errors = config.load(project)
        have = {x[2] for x in d1}
        for msg in cfg_errors:
            if msg not in have:
                d1.append(_e("error", ".crew/crew.json", msg))
        if not cfg and not cfg_errors:
            d1.append(_e("error", ".crew/crew.json", "config did not load"))
    else:
        d1 = [_e("error", ".crew/crew.json", problem)]
    hard = [x for x in d1 if x[0] == "error"]
    entries = _entries("D01", d1, ".crew/crew.json")
    ids = ("D23", "D24") if changed_only else MVP[1:]
    if hard:
        # The other checks need a valid config. Report them as skipped.
        for cid in ids + (() if changed_only else PHASE2):
            entries.append({"id": cid, "level": "skip", "path": "", "text": "crew.json is invalid"})
        return _order(entries, changed_only)
    c = Ctx(project, raw, cfg)
    for cid in ids:
        entries += _entries(cid, _safe(cid, c), ".")
    if not changed_only:
        for cid in PHASE2:
            entries.append({"id": cid, "level": "skip", "path": "", "text": "phase 2"})
    return _order(entries, changed_only)


def _order(entries, changed_only):
    entries.sort(key=lambda e: e["id"])  # stable: keeps the order inside one check
    if changed_only:
        return [e for e in entries if e["id"] in ("D23", "D24") or (e["id"] == "D01" and e["level"] == "error")]
    return entries


def run_doctor(args) -> int:
    project = config.find_project(os.getcwd())
    if project is None:
        print("crew doctor: not inside a crew project", file=sys.stderr)
        return 8
    entries = check(project, changed_only=bool(getattr(args, "changed", False)))
    if getattr(args, "strict", False):
        for e in entries:
            if e["level"] == "warn":
                e["level"] = "error"
    errors = sum(e["level"] == "error" for e in entries)
    warnings = sum(e["level"] == "warn" for e in entries)
    if getattr(args, "json", False):
        print(json.dumps({"errors": errors, "warnings": warnings, "checks": entries}, indent=2))
    else:
        for e in entries:
            if e["level"] == "skip":
                print("%s skip" % e["id"])
            else:
                print("%s %s %s: %s" % (e["id"], e["level"], e["path"], e["text"]))
    return 7 if errors else 0
