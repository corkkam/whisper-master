"""crew init, install, add-component and add-persona (spec 13.1, 13.3, 14.1, 14.2)."""
from __future__ import annotations

import copy
import json
import os
import re
import shutil
import sys
from datetime import datetime

from crew import __version__, config

KIT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
TEMPLATES = os.path.join(KIT, "crew", "templates")

NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9-]{1,23}$")
ID_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
BEGIN, END = "<!-- crew:begin -->", "<!-- crew:end -->"
LEAD_ID = "lead"  # build notes: the id stays "lead", so a rename edits only crew.json
PERSONA_ROLES = ("pm", "qa", "design", "marketing", "user", "architect")
ROLE_WORDS = {"pm": "product manager", "qa": "QA", "design": "designer", "marketing": "marketer",
              "user": "user voice", "architect": "architect"}
CONSULT_ON = {
    "pm": ["user-facing", "pricing", "release", "public-api", "irreversible"],
    "qa": ["data-format", "release", "security", "irreversible"],
    "design": ["user-facing"],
    "marketing": ["user-facing", "pricing", "release", "launch"],
    "user": ["user-facing", "pricing", "launch"],
    "architect": ["data-format", "public-api", "security", "privacy", "irreversible"],
}
PERSONA_NAMES = {"pm": "Maya", "qa": "Quinn", "design": "Iris", "marketing": "Nova", "user": "Juno",
                 "architect": "Theo"}
MODEL = {"lead": "opus", "component": "sonnet", "helper": "haiku"}
EFFORT = {"lead": "high", "component": "high", "helper": "low"}
GITIGNORE = "ledger.jsonl\nledger.lock\nSTOP\ntasks/\ninbox/\n*.tmp\n"
SCAN_TAGS = {"ui": "user-facing", "web": "user-facing", "app": "user-facing", "components": "user-facing",
             "copy": "user-facing", "auth": "security", "secrets": "security", "scripts": "release",
             "release": "release", ".github": "release"}
SCAN_SKIP = {".git", ".build", "node_modules", ".claude"}
PENDING = os.path.join(".crew", "agents-block.pending.md")
BLOCK_MAX_LINES, LEAD_MAX_BYTES = 60, 4096  # the limits that crew doctor checks

_C = '"$HOME"/.crew/bin/crew hook '


def _h(name, timeout, is_async=False):
    h = {"type": "command", "command": _C + name}
    if is_async:
        h["async"] = True
    h["timeout"] = timeout
    return h


# Spec 14.1, without onFailure on the guard: build notes say a shim crash must not block the owner.
HOOKS = {
    "SessionStart": [{"hooks": [_h("session-start", 10), _h("event", 10, True)]}],
    "SubagentStart": [{"hooks": [_h("session-start", 10), _h("event", 10, True)]}],
    "UserPromptSubmit": [{"hooks": [_h("session-start", 5), _h("event", 10, True)]}],
    "PreToolUse": [{"matcher": "*", "hooks": [_h("guard", 10), _h("event", 10, True)]}],
    "PostToolUse": [{"matcher": "*", "hooks": [_h("event", 10, True)]}],
    "PostToolUseFailure": [{"matcher": "*", "hooks": [_h("event", 10, True)]}],
    "PermissionRequest": [{"matcher": "*", "hooks": [_h("event", 10, True)]}],
    "Notification": [{"matcher": "permission_prompt|idle_prompt|agent_needs_input",
                      "hooks": [_h("event", 10, True)]}],
    "SubagentStop": [{"hooks": [_h("event", 5)]}],
    "Stop": [{"hooks": [_h("event", 5)]}],
    "StopFailure": [{"hooks": [_h("event", 10, True)]}],
    "SessionEnd": [{"hooks": [_h("event", 5)]}],
}


class Usage(Exception):
    """Exit 2 with this message."""


# ---------------------------------------------------------------- helpers

def _err(msg: str) -> None:
    sys.stderr.write("crew: %s\n" % msg)


def _list(text) -> list:
    return [x.strip() for x in (text or "").split(",") if x.strip()]


def _read(path: str):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return None


def _write(path: str, text: str) -> None:
    # A symlinked file keeps its link: write the real file.
    if os.path.islink(path):
        path = os.path.realpath(path)
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def _json(obj) -> str:
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def _template(rel: str) -> str:
    with open(os.path.join(TEMPLATES, rel), encoding="utf-8") as fh:
        return fh.read()


def render(text: str, values: dict) -> str:
    return re.sub(r"\{\{(\w+)\}\}", lambda m: str(values[m.group(1)]), text)


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _today() -> str:
    return datetime.now().astimezone().date().isoformat()


def _check_tags(cfg: dict, tags: list) -> None:
    valid = (cfg.get("gates") or {}).get("tags") or config.DEFAULTS["gates"]["tags"]
    bad = [t for t in tags if t not in valid]
    if bad:
        raise Usage("unknown gate tag %s (valid: %s)" % (", ".join(bad), ", ".join(valid)))


def _check_name(name, flag: str = "--name") -> str:
    # The name goes into YAML front matter and the roster table: no newline, ":" or "|".
    if not NAME_RE.match(name or ""):
        raise Usage("%s must match %s" % (flag, NAME_RE.pattern))
    return name


MODEL_RE = re.compile(r"^[A-Za-z0-9._\[\]-]+$")
EFFORTS = ("low", "medium", "high", "xhigh", "max")


def _check_model(model, effort=None) -> None:
    # Both go into YAML front matter: no newline or other raw text.
    if model is not None and not MODEL_RE.match(model):
        raise Usage("--model must match %s" % MODEL_RE.pattern)
    if effort is not None and effort not in EFFORTS:
        raise Usage("--effort must be one of %s" % ", ".join(EFFORTS))


def _opus_cap(cfg: dict, agent: dict) -> None:
    """Raise max_budget_usd above the call reserve of the agent's model (doctor D19)."""
    reserve = ((cfg.get("budget") or {}).get("call_reserve_usd")
               or config.DEFAULTS["budget"]["call_reserve_usd"])
    r = reserve.get(agent.get("model"))
    if isinstance(r, (int, float)) and not isinstance(r, bool):
        agent["max_budget_usd"] = round(r + 0.5, 2)


def _check_lens(lens: str) -> str:
    lens = lens.replace("\\n", "\n").strip()
    lines = [x for x in lens.splitlines() if x.strip()]
    if not 3 <= len(lines) <= 6:
        raise Usage("--lens needs 3 to 6 lines (separate lines with a newline or \\n)")
    return "\n".join(lines)


# ---------------------------------------------------------------- agent files

def _yaml_inner(text) -> str:
    """Text safe inside a double-quoted YAML scalar (JSON escapes)."""
    return json.dumps(str(text), ensure_ascii=False)[1:-1]


def agent_file(agent: dict, cfg: dict, lens=None) -> str:
    """The text of .claude/agents/<id>.md for one crew.json agent."""
    role = agent.get("role")
    kind = role if role in ("lead", "component", "helper", "qa") else "persona"
    values = {
        "id": agent["id"], "name": agent.get("name") or agent["id"],
        "project": (cfg.get("project") or {}).get("name", ""),
        "project_q": _yaml_inner((cfg.get("project") or {}).get("name", "")),
        "model": agent.get("model") or MODEL.get(role, "sonnet"),
        "effort": agent.get("effort") or EFFORT.get(role, "medium"),
        "consult_on": ", ".join(agent.get("consult_on") or []) or "none",
        "role_words": ROLE_WORDS.get(role, agent["id"].replace("-", " ")),
        "component_dir": agent.get("component_dir", ""),
        "paths": ", ".join("`%s`" % p for p in agent.get("paths") or []),
        "lens": lens or "",
    }
    text = _template("agents/%s.md" % kind)
    if kind == "lead":
        out = render(text, values)
        if len(out.encode("utf-8")) > LEAD_MAX_BYTES:
            raise Usage("the lead file would be over 4 KiB. Use a shorter lead or project name")
        return out
    if kind == "persona":
        # Keep only the lens block of this role.
        want = role if role in ROLE_WORDS else "custom"
        if want == "custom" and not lens:
            raise Usage("persona %s needs --lens" % agent["id"])
        blocks = dict(re.findall(r"<!-- lens:(\w+) -->\n(.*?)(?=<!-- lens:)", text, re.S))
        text = re.sub(r"<!-- lens:\w+ -->\n.*<!-- lens:end -->\n", lambda m: blocks[want], text, flags=re.S)
    return render(text, values)


def _skill(name: str, cfg: dict) -> str:
    return render(_template("skills/%s/SKILL.md" % name), {"lead": cfg.get("lead", LEAD_ID)})


def crew_block(cfg: dict) -> str:
    rows = []
    for a in cfg.get("agents") or []:
        role = a.get("role", "")
        rows.append("| %s | %s | %s | %s |" % (a["id"], role, a.get("name") or a["id"],
                                             a.get("model") or MODEL.get(role, "sonnet")))
    routing = []
    for i, r in enumerate(cfg.get("routing") or []):
        when = r.get("when") or {}
        cond = ", ".join("%s %s" % (k, v if isinstance(v, str) else ",".join(v)) for k, v in when.items())
        acts = []
        if r.get("assign"):
            acts.append("assign " + r["assign"])
        if r.get("consult"):
            acts.append("consult " + ", ".join(r["consult"]))
        if r.get("gates"):
            acts.append("gates " + ", ".join(r["gates"]))
        routing.append("- Rule %d: %s -> %s." % (i, cond or "every task", "; ".join(acts) or "no change"))
    huddle = cfg.get("huddle") or config.DEFAULTS["huddle"]
    text = render(_template("agents-block.md"), {
        "lead": cfg.get("lead", LEAD_ID), "roster": "\n".join(rows),
        "max_advisers": huddle.get("max_advisers", 3),
        "routing": "\n".join(routing) or "- No routing rules.",
        "owner_tags": ", ".join(huddle.get("owner_tags") or []),
    })
    n = len(text.rstrip("\n").splitlines())
    if n > BLOCK_MAX_LINES:
        raise Usage("the crew block would have %d lines, limit %d" % (n, BLOCK_MAX_LINES))
    return text


def _with_block(agents_md, block: str) -> str:
    """AGENTS.md text with the crew block replaced, or appended when the markers are absent."""
    if agents_md is None:
        return "# AGENTS.md\n\n" + block
    i, j = agents_md.find(BEGIN), agents_md.find(END)
    if i >= 0 and j > i:
        return agents_md[:i] + block.rstrip("\n") + agents_md[j + len(END):]
    sep = "" if agents_md.endswith("\n\n") else ("\n" if agents_md.endswith("\n") else "\n\n")
    return agents_md + sep + block


def _block_writes(project: str, cfg: dict, pending: bool) -> dict:
    """Files that carry the crew block: AGENTS.md when it has markers (or init appends), else the pending file."""
    block = crew_block(cfg)
    path = os.path.join(project, "AGENTS.md")
    cur = _read(path)
    if pending:
        return {os.path.join(project, PENDING): block}
    out = {path: _with_block(cur, block)}
    if cur is None and not os.path.exists(os.path.join(project, "CLAUDE.md")):
        out[os.path.join(project, "CLAUDE.md")] = "@AGENTS.md\n"
    return out


def _rewrite_block(project: str, cfg: dict) -> dict:
    """For add-component and add-persona: replace the block in AGENTS.md, else refresh the pending file."""
    cur = _read(os.path.join(project, "AGENTS.md"))
    has = cur is not None and BEGIN in cur and END in cur
    return _block_writes(project, cfg, pending=not has)


# ---------------------------------------------------------------- init

def scan_rules(project: str) -> list:
    """Spec 13.3 folder scan: default gate rules from folder names."""
    found = {}
    root_depth = project.rstrip("/").count("/")
    for d, dirs, _files in os.walk(project):
        keep = []
        for name in sorted(dirs):
            if name in SCAN_SKIP or (name.startswith(".") and name != ".github"):
                continue
            tag = SCAN_TAGS.get(name.lower())
            if tag:
                rel = os.path.relpath(os.path.join(d, name), project).replace(os.sep, "/")
                found.setdefault(tag, []).append(rel + "/")
            else:
                keep.append(name)
        # Do not descend into a matched folder, nor past depth 6.
        dirs[:] = keep if d.rstrip("/").count("/") - root_depth < 5 else []
    order = config.DEFAULTS["gates"]["tags"]
    return [{"tag": t, "paths": sorted(found[t])} for t in order if t in found]


def new_config(project: str, lead_name: str, project_name: str, personas: list, helper: bool) -> dict:
    d = copy.deepcopy(config.DEFAULTS)
    agents = [{"id": LEAD_ID, "role": "lead", "name": lead_name, "model": "opus", "effort": "high",
               "max_budget_usd": 3.0}]
    for role in personas:
        name = PERSONA_NAMES[role] if PERSONA_NAMES[role].lower() != lead_name.lower() else role
        agents.append({"id": role, "role": role, "name": name, "consult_on": list(CONSULT_ON[role])})
    if helper:
        name = "Scout" if lead_name.lower() != "scout" else "helper"
        agents.append({"id": "scout", "role": "helper", "name": name, "model": "haiku", "effort": "low"})
    routing = []
    if "qa" in personas:
        routing.append({"when": {"type": "qa"}, "assign": "qa", "consult": ["pm"] if "pm" in personas else []})
    # Only the personas that exist: doctor D20 fails on an unknown id.
    d["huddle"]["priority"] = [r for r in d["huddle"]["priority"] if r in personas]
    gates = d["gates"]
    gates["rules"] = scan_rules(project)
    # Build notes renamed the window keys. Write only the owner's names.
    for old, new in (("five_hour_max_pct", "max_five_hour_pct"), ("seven_day_max_pct", "max_seven_day_pct")):
        if new in d["budget"]:
            d["budget"].pop(old, None)
    auto = d["autonomy"]
    d["autonomy"] = {"level": auto.get("level", "L2"), "set_at": _now(), "expires_at": auto.get("expires_at"),
                     "set_by": auto.get("set_by", "owner")}
    cfg = {"version": 1, "project": {"name": project_name, "public_paths": []}, "lead": LEAD_ID,
           "agents": agents, "gates": gates, "routing": routing}
    for key in ("huddle", "budget", "autonomy", "guard", "eval", "doctor", "context"):
        if key in d:
            cfg[key] = d[key]
    return cfg


def merge_settings(current):
    """Spec 14.2: add each crew hook command that the event does not have yet."""
    out = copy.deepcopy(current) if current else {}
    hooks = out.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise Usage(".claude/settings.json: hooks must be an object")
    for event, groups in HOOKS.items():
        existing = hooks.setdefault(event, [])
        if not isinstance(existing, list):
            raise Usage(".claude/settings.json: hooks.%s must be a list" % event)
        if not all(isinstance(g, dict) and (g.get("hooks") is None or isinstance(g["hooks"], list))
                   for g in existing):
            raise Usage(".claude/settings.json: hooks.%s must hold groups with a hooks list" % event)
        have = {h.get("command") for g in existing
                for h in (g.get("hooks") or []) if isinstance(h, dict)}
        for g in groups:
            new = [copy.deepcopy(h) for h in g["hooks"] if h["command"] not in have]
            if new:
                grp = copy.deepcopy(g)
                grp["hooks"] = new
                existing.append(grp)
    return out


def _settings_write(project: str) -> dict:
    path = os.path.join(project, ".claude", "settings.json")
    text = _read(path)
    cur = {}
    if text is not None and text.strip():
        try:
            cur = json.loads(text)
        except ValueError as exc:
            raise Usage(".claude/settings.json is not valid JSON: %s" % exc)
        if not isinstance(cur, dict):
            raise Usage(".claude/settings.json must hold a JSON object")
    merged = merge_settings(cur)
    return {} if merged == cur else {path: _json(merged)}


def _agent_writes(project: str, cfg: dict, keep_custom: bool) -> dict:
    out = {}
    for a in cfg.get("agents") or []:
        path = os.path.join(project, ".claude", "agents", a["id"] + ".md")
        if a.get("role") == "custom" and keep_custom:
            continue  # its lens lives only in the agent file
        out[path] = agent_file(a, cfg)
    for name in ("crew-huddle", "crew-retro"):
        out[os.path.join(project, ".claude", "skills", name, "SKILL.md")] = _skill(name, cfg)
    return out


def _apply(project: str, writes: dict, dry_run: bool) -> None:
    # crew.json last: a failed write leaves no crew.json, so a retry of init is not refused.
    for path in sorted(writes, key=lambda p: (os.path.basename(p) == "crew.json", p)):
        rel = os.path.relpath(path, project)
        if dry_run:
            print("would write " + rel)
        else:
            _write(path, writes[path])
            print("wrote " + rel)


def _init(args) -> int:
    project = os.getcwd()
    for rel in (".claude", os.path.join(".claude", "agents")):
        if os.path.islink(os.path.join(project, rel)):
            raise Usage("replace the .claude/agents symlink with a folder first")
    exists = os.path.isfile(os.path.join(project, ".crew", "crew.json"))
    pending = bool(getattr(args, "no_agents_block", False))
    dry = bool(getattr(args, "dry_run", False))
    if exists and not getattr(args, "force", False):
        raise Usage(".crew/crew.json exists. Use --force to rewrite the agent files, skills and crew block")
    if exists:
        cfg, errors = config.load(project)
        if errors:
            raise Usage("; ".join(errors))
        writes = _agent_writes(project, cfg, keep_custom=True)
        # Replace the block only between markers. Else refresh the pending file. Never append or create files.
        writes.update(_block_writes(project, cfg, True) if pending else _rewrite_block(project, cfg))
        _apply(project, writes, dry)
        return 0

    name = getattr(args, "lead_name", None)
    if not name:
        if not sys.stdin.isatty():
            raise Usage("--lead-name is required when stdin is not a TTY")
        name = input("Lead name: ").strip()
    _check_name(name, "lead name")
    personas = _list(getattr(args, "personas", None) or ",".join(PERSONA_ROLES))
    bad = [p for p in personas if p not in PERSONA_ROLES]
    if bad:
        raise Usage("unknown persona %s (valid: %s)" % (", ".join(bad), ", ".join(PERSONA_ROLES)))
    pname = getattr(args, "project_name", None) or os.path.basename(project.rstrip("/"))
    cfg = new_config(project, name, pname, list(dict.fromkeys(personas)), not getattr(args, "no_helper", False))

    writes = _settings_write(project)  # first: invalid JSON stops before any write
    writes.update({
        os.path.join(project, ".crew", "crew.json"): _json(cfg),
        os.path.join(project, ".crew", ".gitignore"): GITIGNORE,
        os.path.join(project, ".crew", "STATE.md"): render(_template("STATE.md"),
                                                          {"updated": _now(), "lead": LEAD_ID}),
        os.path.join(project, ".crew", "BACKLOG.md"): _template("BACKLOG.md"),
    })
    writes.update(_agent_writes(project, cfg, keep_custom=False))
    writes.update(_block_writes(project, cfg, pending))
    stubs = {"DECISIONS.md": "# Decisions\n\nNewest first. One `## YYYY-MM-DD` heading per day, one bullet per "
                             "decision with who decided and why.\n",
             "ARCHITECTURE.md": _template("ARCHITECTURE.md"),
             os.path.join("memory", "MEMORY.md"): "# Memory\n\nOne line per note, at most 150 characters.\n"}
    for rel, text in stubs.items():
        if not os.path.exists(os.path.join(project, rel)):
            writes[os.path.join(project, rel)] = text
    _apply(project, writes, dry)
    if dry:
        home = config.crew_home()
        print("would install " + os.path.join(home, "kit", __version__) + "/")
        print("would write " + os.path.join(home, "bin", "crew"))
        return 0
    print("installed " + install_kit(False))
    print("Next: claude --agent %s, or crew run \"<task>\"" % LEAD_ID)
    return 0


def run_init(args) -> int:
    try:
        return _init(args)
    except Usage as exc:
        _err(str(exc))
        return 2


# ---------------------------------------------------------------- install

def _sh_quote(path: str) -> str:
    return '"%s"' % re.sub(r'(["$`\\])', r"\\\1", path)


def install_kit(force: bool) -> str:
    """Copy crew-kit/bin and crew-kit/crew to crew_home()/kit/<version>/ and write the shim. Returns the shim path."""
    home = config.crew_home()
    dest = os.path.join(home, "kit", __version__)
    src_real, dest_real = os.path.realpath(KIT), os.path.realpath(dest)
    # Running from the installed copy: never copy a folder onto itself.
    if src_real != dest_real and (force or not os.path.isdir(dest)):
        tmp = dest + ".tmp"
        shutil.rmtree(tmp, ignore_errors=True)
        ignore = shutil.ignore_patterns("__pycache__", "*.pyc", "*.tmp")
        for part in ("bin", "crew"):
            shutil.copytree(os.path.join(KIT, part), os.path.join(tmp, part), ignore=ignore)
        if os.path.isdir(dest):
            shutil.rmtree(dest)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        os.rename(tmp, dest)
    target = os.path.join(dest, "bin", "crew")
    if os.path.realpath(home) == os.path.realpath(os.path.expanduser("~/.crew")):
        target_sh = '"$HOME/.crew/kit/%s/bin/crew"' % __version__
    else:
        target_sh = _sh_quote(target)
    shim = os.path.join(home, "bin", "crew")
    _write(shim, '#!/bin/sh\nexec %s -I %s "$@"\n' % (_sh_quote(os.path.realpath(sys.executable)), target_sh))
    os.chmod(shim, 0o755)
    return shim


def run_install(args) -> int:
    try:
        shim = install_kit(bool(getattr(args, "force", False)))
    except OSError as exc:
        _err("cannot install: %s" % exc)
        return 1
    print("%s (crew %s)" % (shim, __version__))
    return 0


# ---------------------------------------------------------------- add-component, add-persona

def _project_cfg():
    project = config.find_project(os.getcwd())
    if not project:
        return None, None
    path = os.path.join(project, ".crew", "crew.json")
    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)  # raw, not config.load: keep key order and omit defaults
    except (OSError, ValueError) as exc:
        raise Usage("cannot read %s: %s" % (path, exc))
    if not isinstance(raw, dict) or not isinstance(raw.get("agents"), list):
        raise Usage("crew.json has no agents list")
    return project, raw


def _add(args, build) -> int:
    try:
        project, raw = _project_cfg()
        if project is None:
            _err("not inside a crew project (no .crew/crew.json above this folder)")
            return 8
        agent, writes = build(project, raw)
        if config.agent(raw, agent["id"]):
            raise Usage("agent %s exists" % agent["id"])
        raw["agents"].append(agent)
        writes[os.path.join(project, ".crew", "crew.json")] = _json(raw)
        writes.update(_rewrite_block(project, raw))
        _apply(project, writes, bool(getattr(args, "dry_run", False)))
        return 0
    except Usage as exc:
        _err(str(exc))
        return 2
    except (TypeError, AttributeError, KeyError) as exc:
        _err("bad crew.json: %s: %s" % (type(exc).__name__, exc))
        return 2


def run_add_component(args) -> int:
    def build(project, raw):
        cid = args.id[2:] if args.id.startswith("c-") else args.id
        aid = "c-" + cid
        if not ID_RE.match(aid) or not ID_RE.match(cid):
            raise Usage("component id must match %s" % ID_RE.pattern)
        comp_dir = args.dir.strip().rstrip("/").replace(os.sep, "/")
        if not comp_dir or os.path.isabs(comp_dir) or ".." in comp_dir.split("/"):
            raise Usage("--dir must be a folder inside the project")
        if not os.path.isdir(os.path.join(project, comp_dir)):
            raise Usage("--dir %s does not exist" % comp_dir)
        name = _check_name(getattr(args, "name", None) or cid.title())
        agent = {"id": aid, "role": "component", "name": name}
        _check_model(getattr(args, "model", None), getattr(args, "effort", None))
        for key in ("model", "effort"):
            if getattr(args, key, None):
                agent[key] = getattr(args, key)
        consult = _list(getattr(args, "consult_on", None))
        _check_tags(raw, consult)
        if consult:
            agent["consult_on"] = consult
        agent["component_dir"] = comp_dir
        agent["paths"] = _list(getattr(args, "paths", None)) or [comp_dir + "/"]
        _opus_cap(raw, agent)
        writes = {os.path.join(project, ".claude", "agents", aid + ".md"): agent_file(agent, raw)}
        iface = os.path.join(project, comp_dir, "INTERFACE.md")
        if not os.path.exists(iface):
            writes[iface] = render(_template("INTERFACE.md"), {"name": name, "id": aid, "today": _today()})
        dec = os.path.join(project, comp_dir, "DECISIONS.md")
        if not os.path.exists(dec):
            writes[dec] = "# %s decisions\n" % name
        return agent, writes
    return _add(args, build)


def run_add_persona(args) -> int:
    def build(project, raw):
        pid = args.id
        if not ID_RE.match(pid):
            raise Usage("persona id must match %s" % ID_RE.pattern)
        role = getattr(args, "role", None) or "custom"
        if role not in PERSONA_ROLES + ("custom",):
            raise Usage("--role must be one of %s, custom" % ", ".join(PERSONA_ROLES))
        name = _check_name(args.name)
        consult = _list(args.consult_on)
        if not consult:
            raise Usage("--consult-on needs at least one gate tag")
        _check_tags(raw, consult)
        lens = getattr(args, "lens", None)
        if (role == "custom") != bool(lens):
            raise Usage("--lens is required for a custom persona, and only for one")
        lens = _check_lens(lens) if lens else None
        agent = {"id": pid, "role": role, "name": name}
        model = getattr(args, "model", None)
        _check_model(model)
        if model and model != "sonnet":
            agent["model"] = model
        agent["consult_on"] = consult
        _opus_cap(raw, agent)
        text = agent_file(agent, raw, lens=lens)
        if len(text.encode("utf-8")) > 2048:
            raise Usage("the persona file is over 2 KiB. Use a shorter --lens")
        return agent, {os.path.join(project, ".claude", "agents", pid + ".md"): text}
    return _add(args, build)
