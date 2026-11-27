---
name: crew-huddle
description: Run a Crew huddle at a gate. Use it once per task when a crew route has "huddle": true. The lead chairs. Advisers and subjects give one opinion each.
---

`crew` below is `"$HOME"/.crew/bin/crew`. `<lead>` is `{{lead}}`.

## Who joins

The route JSON gives the list: `advisers` (at most `huddle.max_advisers`) and `subjects` (component agents, not counted). With several parts, use the union over the parts. The cap applies to the union. You chair and give no opinion. Nobody else joins.

## Rounds

1. Run `crew emit huddle.start --agent <lead> --agents <advisers and subjects, comma list> --task <task_id>`.
2. Open question. When there is a subject, call the first subject first: "State the open question for your change in 2 sentences." Put the answer in `## Open question` of `plan.md`. With no subject, write it yourself.
3. Round 1. One Agent call per participant, in sequence. The prompt has only: the open question, the plan path, the touched paths, the gate tags, and "Answer with the crew opinion JSON only, at most 300 words." Subjects answer "Is this the right way in the code?". Advisers answer "Is this what the user wants?" from their lens. No transcript.
4. Save each answer to `.crew/tasks/<task_id>/huddle.md`.
5. If no answer has `"verdict": "block"`, go to step 8.
6. Round 2, only after a block. Revise the plan. Send the revised plan to every participant, with the blocking concerns and the `suggestion` line of every other opinion (not their concerns). Each answers once more with `"round": 2`. Run `crew emit huddle.round --agent <lead> --agents <all participants> --task <task_id> --note "round 2"`.
7. There is never a round 3.
8. Decide. Write `## Decision` in `huddle.md`: the choice, the reason and each dissent. A block that remains after round 2, on a gate tag in `huddle.hard_block_tags`: do not execute. End with `blocked`. The owner decides. Any other remaining block: you decide and record the dissent. When `owner_gate` is true and the header says `approved=false`, end with `needs_approval`, whatever the verdicts.
9. Run `crew emit huddle.end --agent <lead> --agents <same list as start> --task <task_id>`.
10. A lasting choice also goes into a decision entry.

## Opinion schema

The participant's final message is one fenced JSON object:

```json
{"crew_opinion": 1, "agent": "pm", "round": 1, "verdict": "change",
 "concerns": ["<at most 60 words>"], "suggestion": "<at most 120 words>", "evidence": ["path:line"]}
```

`verdict` is `approve`, `change` or `block`. 0 to 3 concerns. 0 to 5 evidence items (`path:line` or a command). All words together at most `huddle.max_words`. Record an answer that does not parse as `{"verdict": "change", "concerns": ["no valid opinion"]}`. Do not ask again.

## Cost cap

At most `huddle.max_advisers` advisers plus at most 3 subjects. One answer each, at most 300 words. Round 2 only after a block.

## Record

`.crew/tasks/<task_id>/huddle.md`:

```markdown
# Huddle <task_id>
Gate tags: <tags>
Advisers: <ids>. Skipped: <ids or none>. Subjects: <ids or none>.
## Round 1
<one fenced opinion JSON per participant>
## Round 2
None
## Decision
<choice, reason, dissent>
```
