---
name: brainstorming
description: Use before implementing new behavior, refactors with meaningful design choices, or changes that alter user-visible behavior. Clarify intent, propose approaches, write a short spec, and only then transition to planning.
---

# Brainstorming

Use this skill for design work before implementation.

## Checklist

1. Read the nearest owning code, test, or documentation.
2. Ask only the smallest set of missing questions needed to remove ambiguity.
3. Propose 2-3 approaches when there is a real design choice.
4. Recommend one approach with concrete reasoning.
5. Write a short spec.
6. Get user approval if the change affects scope, behavior, or operational contract.
7. Hand off to `writing-plans`.

## Spec Requirements

The spec should be short and operational, not aspirational.

Include:

- goal
- current context
- constraints and invariants
- recommended approach
- alternatives considered
- acceptance checks
- open questions

If the task is truly small, the spec can still be brief. The point is to make the intended behavior explicit before code changes.

## Helper

Use the scaffold when it saves time:

```bash
bash .claude/skills/superpowerz/scripts/new_spec.sh feature-slug "Short Feature Title"
```

Default location:

`tmp/superpowerz/specs/YYYY-MM-DD-feature-slug.md`

## Design Standard

Prefer the smallest design that satisfies the requirement and preserves repository invariants.

Do not broaden scope with unrelated cleanup unless the current task cannot be done safely without it.

## Exit Condition

Do not move to implementation directly from ambiguity.

Exit this skill by routing into `.claude/skills/writing-plans/SKILL.md` once the design is clear enough to slice into implementation work.

After planning is complete, route into `.claude/skills/executing-plans/SKILL.md` rather than improvising execution.
