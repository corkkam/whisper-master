---
name: crew-retro
description: Run the Crew retro at the end of a task. Use it once, after the record step and before the crew_result line. Skip it on the fast path.
---

The retro turns this task into lessons. Use evidence from this run only: test output, files, `huddle.md`, guard denies. "No lesson" is a valid result.

1. Write 0 to 3 lessons to your own memory. One line in your `MEMORY.md` for each note, at most 150 characters: the fact and the reason. Write only what the code does not show. Do not repeat a lesson that is there.
2. For each agent that ran, write 0 to 2 candidate changes to `.crew/tasks/<task_id>/retro.md`, one line each, in this form:
   `- [tier A|B|C] <agent id>: <change>, evidence: <run or file>`
3. Tiers:
   - A: agent memory notes, `STATE.md`, session records, `retro.md`. Written at once.
   - B: agent file bodies and descriptions, skill text, `INTERFACE.md`, the crew block prose in `AGENTS.md`. A PR from a `crew-improve-*` worktree only. In this build, write the line and nothing else.
   - C: `crew.json` (routing, caps, levels, tags), hooks, settings, the kit, eval commands. Owner only. Write the line and nothing else.
4. A tier A lesson for another agent goes to that agent through one short Agent call: "Save this lesson to your memory: ...".
5. Never edit an agent file, a skill, a hook, a setting or `.crew/crew.json` in the retro.
