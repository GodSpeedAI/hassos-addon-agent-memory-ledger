---
description: Prefer the local Superpowerz skill workflow for non-trivial project.sh changes.
applyTo: "project.sh"
---

For non-trivial edits to `project.sh`, prefer the local Superpowerz skill suite instead of ad hoc execution.

Use these local skills as the default workflow router:

- `.claude/skills/using-superpowers/SKILL.md`
- `.claude/skills/brainstorming/SKILL.md`
- `.claude/skills/writing-plans/SKILL.md`
- `.claude/skills/executing-plans/SKILL.md`
- `.claude/skills/systematic-debugging/SKILL.md`
- `.claude/skills/verification-before-completion/SKILL.md`

Expected routing:

- behavior or workflow changes: `using-superpowers` -> `brainstorming` -> `writing-plans` -> `executing-plans`
- bug fixing or failing checks: `using-superpowers` -> `systematic-debugging`
- before any claim of completion or readiness: `verification-before-completion`

Preserve repository invariants and keep operational changes explicit and validated.
