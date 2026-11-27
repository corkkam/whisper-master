<!-- crew:begin -->
## Crew

This project has a Crew agent team. Give every task to the lead `{{lead}}`: `crew run "<task>"` or `claude --agent {{lead}}`. `crew init`, `crew add-component` and `crew add-persona` write this block. Change `.crew/crew.json`, not this block.

| id | role | name | model |
|---|---|---|---|
{{roster}}

Gate tags:
- **data-format**: a stored or wire format changes.
- **public-api**: an `INTERFACE.md` entry changes.
- **privacy**: audio, text that leaves the device, analytics.
- **security**: auth, secrets, permissions, hooks.
- **user-facing**: any behaviour the developer or a user can see: UI, copy, onboarding, notifications.
- **pricing**: price or plan.
- **release**: versions, appcast, release scripts.
- **irreversible**: deletes, migrations, sends.
- **launch**: a launch, a demo, a post or a growth idea.

Routing: `crew route` picks the writer. The first matching rule wins, then the component agents whose `paths` match, then the lead. A gate tag or a rule `consult` list opens a huddle with at most {{max_advisers}} advisers, in `huddle.priority` order. One writer at a time. Personas give opinions only.
{{routing}}

Red lines, at every autonomy level (the guard denies them): no push except `git -C <worktree> push -u origin feature/<slug>`, no merge, release, tag, version bump, deploy, secret, R2 or ticket change, no message to a person, no delete of work, no nested `claude`, `codex` or `crew run`, no edit of protected files.

Owner tags: {{owner_tags}}. A task with one of these tags stops with `needs_approval` until the owner runs `crew run --task-id <id> --approved "<task>"`.
<!-- crew:end -->
