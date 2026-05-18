---
description: Prefer the local Superpowerz skill workflow for non-trivial postgres design documentation changes.
applyTo: "DESIGN-postgres-config.md"
---

For non-trivial edits to `DESIGN-postgres-config.md`, prefer the local Superpowerz skill suite instead of ad hoc execution.

Use these local skills as the default workflow router:

- `.claude/skills/using-superpowers/SKILL.md`
- `.claude/skills/brainstorming/SKILL.md`
- `.claude/skills/writing-plans/SKILL.md`
- `.claude/skills/executing-plans/SKILL.md`
- `.claude/skills/systematic-debugging/SKILL.md`
- `.claude/skills/verification-before-completion/SKILL.md`

Expected routing:

- behavior or contract changes reflected in docs: `using-superpowers` -> `brainstorming` -> `writing-plans` -> `executing-plans`
- before any claim that docs match behavior: `verification-before-completion`

Document invariants, replayability, provenance, and operational tradeoffs directly rather than implying them.