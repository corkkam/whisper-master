"""crew hook event and crew hook session-start (spec sections 12.2 and 14.3).

Both read one JSON object from stdin, never write to stderr and always return 0.
No prompt text, tool input, command or file path goes into an event.
"""
from __future__ import annotations

import json
import os
import sys
import time

from crew import config, events

PERSONA_ROLES = frozenset(["pm", "qa", "design", "marketing", "user", "architect", "custom"])
CONTEXT_MAX = 2048
STATE_MAX = 1500
SESSION_MAX_AGE_S = 7 * 24 * 3600

_SIMPLE = {
    "SubagentStart": "agent.start",
    "SubagentStop": "agent.stop",
    "Stop": "turn.end",
    "StopFailure": "turn.fail",
    "SessionEnd": "session.end",
}


def _is_agent_message(hook):
    prompt = hook.get("prompt")
    # Only the first 15 characters, in memory only (section 12.2).
    return isinstance(prompt, str) and prompt[:15].startswith("<agent-message")


def map_event(hook: dict, agent_id: str, project: str) -> list:
    """Map one hook line to 0, 1 or 2 event dicts (keyword arguments of events.write_event)."""
    name = hook.get("hook_event_name")
    session = hook.get("session_id") if isinstance(hook.get("session_id"), str) else None
    tool = hook.get("tool_name") if isinstance(hook.get("tool_name"), str) else None

    def ev(event, **kw):
        out = {"project": project, "event": event, "agent": agent_id, "src": "claude",
               "session": session, "tool": None, "kind": None, "note": None, "agents": []}
        out.update(kw)
        return out

    if name == "SessionStart":
        out = [ev("session.start")]
        if hook.get("source") in ("clear", "compact"):
            out.append(ev("context.clear", note=hook.get("source")))
        return out
    if name == "UserPromptSubmit":
        return [] if _is_agent_message(hook) else [ev("prompt")]
    if name in ("PreToolUse", "PostToolUse"):
        command = None
        if tool == "Bash" and isinstance(hook.get("tool_input"), dict):
            command = hook["tool_input"].get("command")  # read in memory for the kind only
            command = command if isinstance(command, str) else None
        return [ev("tool.start" if name == "PreToolUse" else "tool.end",
                   tool=tool, kind=events.kind_for(tool or "", command))]
    if name == "PostToolUseFailure":
        # No measured sample: tool_name only, never tool_input.
        return [ev("tool.fail", tool=tool, kind=events.kind_for(tool or ""))]
    if name == "PermissionRequest":
        return [ev("needs.input", note="permission")]
    if name == "Notification":
        return [ev("needs.input", note="waiting")]
    if name in _SIMPLE:
        return [ev(_SIMPLE[name])]
    return []


def _read_hook():
    data = json.loads(sys.stdin.read() or "null")
    return data if isinstance(data, dict) else None


def _identity(hook):
    """(project, cfg, agent id) for a crew agent line, else None. Built-in subagents give None."""
    project = config.resolve_project(hook, os.environ)
    if not project:
        return None
    cfg, errors = config.load(project)
    if errors:
        return None
    agent_id, builtin = config.resolve_agent(hook, cfg, os.environ)
    if not agent_id or builtin or config.agent(cfg, agent_id) is None:
        return None
    return project, cfg, agent_id


def run_hook_event(args) -> int:
    try:
        hook = _read_hook()
        ident = _identity(hook) if hook else None
        if not ident:
            return 0
        project, _cfg, agent_id = ident
        for e in map_event(hook, agent_id, project):
            kw = dict(e)
            events.write_event(kw.pop("project"), kw.pop("event"), kw.pop("agent"), **kw)
    except Exception:
        pass
    return 0


def _emit_context(event_name, text):
    data = text.encode("utf-8")
    if len(data) > CONTEXT_MAX:
        text = data[:CONTEXT_MAX].decode("utf-8", "ignore")
    sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": event_name,
                                                        "additionalContext": text}}) + "\n")
    sys.stdout.flush()


def _prune_sessions():
    d = os.path.join(config.crew_home(), "sessions")
    cutoff = time.time() - SESSION_MAX_AGE_S
    try:
        entries = list(os.scandir(d))
    except OSError:
        return
    for entry in entries:
        try:
            if entry.is_file() and entry.stat().st_mtime < cutoff:
                os.remove(entry.path)
        except OSError:
            continue


def _session_start_text(project, cfg, agent_id):
    me = config.agent(cfg, agent_id) or {}
    rows = config.read_ledger(project, tail_bytes=262144)
    level = config.effective_level(cfg, rows)
    spent = config.spent(rows, day=time.strftime("%Y-%m-%d"))
    per_day = (cfg.get("budget") or {}).get("per_day_usd", 10.0)
    cap = "no cap" if per_day is None else "$%.2f" % float(per_day)
    stop = "set" if config.stop_set(project) else "not set"
    try:
        with open(os.path.join(project, ".crew", "STATE.md"), "rb") as fh:
            state = fh.read(STATE_MAX).decode("utf-8", "ignore")
    except OSError:
        state = "(none)"
    return ("Crew: you are %s (%s, %s) in project %s. Autonomy %s. Budget today $%.2f of %s. STOP: %s.\n"
            ".crew/STATE.md:\n%s" % (agent_id, me.get("role"), me.get("name") or agent_id,
                                     (cfg.get("project") or {}).get("name"), level, spent, cap, stop, state))


def _subagent_text(cfg, agent_id):
    me = config.agent(cfg, agent_id) or {}
    role = me.get("role")
    if role == "component":
        return ("Crew: you are %s. Write only inside: %s. Read %s/INTERFACE.md and %s/DECISIONS.md "
                "before you change code." % (agent_id, ", ".join(me.get("paths") or []),
                                             me.get("component_dir"), me.get("component_dir")))
    if role in PERSONA_ROLES:
        return ("Crew: you are %s. Give one opinion in the crew opinion schema. Write only to "
                ".claude/agent-memory/%s/ and .crew/tasks/." % (agent_id, agent_id))
    return None


def _new_session(sid, agent_id, project):
    return {"v": 1, "session": sid, "agent": agent_id, "project": project, "task_id": None,
            "run_id": None, "purpose": "task", "autonomous": False, "approved": False,
            "turns": 0, "created_at": config.utc_ts()}


def run_hook_session_start(args) -> int:
    try:
        hook = _read_hook()
        ident = _identity(hook) if hook else None
        if not ident:
            return 0
        project, cfg, agent_id = ident
        name = hook.get("hook_event_name")
        sid = hook.get("session_id") if isinstance(hook.get("session_id"), str) else None
        is_sub = bool(hook.get("agent_id"))

        if name == "SessionStart" and not is_sub:
            if sid:
                smap = config.read_session(sid)
                changed = smap is None
                if smap is None:
                    smap = _new_session(sid, agent_id, project)
                if hook.get("source") in ("clear", "compact"):
                    smap["turns"] = 0
                    changed = True
                if changed:
                    config.write_session(sid, smap)
            _emit_context("SessionStart", _session_start_text(project, cfg, agent_id))
            _prune_sessions()
        elif name == "SubagentStart" and is_sub:
            text = _subagent_text(cfg, agent_id)
            if text:
                _emit_context("SubagentStart", text)
        elif name == "UserPromptSubmit" and not is_sub and sid and not _is_agent_message(hook):
            smap = config.read_session(sid)
            if smap is None:
                return 0
            turns = int(smap.get("turns") or 0) + 1
            smap["turns"] = turns
            config.write_session(sid, smap)
            max_turns = int((cfg.get("context") or {}).get("max_turns") or 8)
            if turns == max_turns or (turns > max_turns and (turns - max_turns) % 4 == 0):
                _emit_context("UserPromptSubmit", (
                    "Crew: this session has had %d prompts. Write .crew/STATE.md now (current task, last step, "
                    "next step, open questions, files touched). Then tell the developer: run /clear to start a "
                    "fresh context. STATE.md comes back after the clear." % turns))
    except Exception:
        pass
    return 0
