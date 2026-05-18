---
name: writing-plans
description: Use after the design is clear or approved and before non-trivial implementation. Break the work into small executable slices with exact files, validations, and exit criteria.
---

# Writing Plans

Use this skill to convert a clear design into a plan that can be executed without guessing.

## Planning Rules

1. Break work into small, coherent slices.
2. Name the exact files, symbols, or tests when known.
3. Give each slice a concrete validation command.
4. Call out risks to repository invariants or user-visible behavior.
5. Prefer the next smallest useful step over broad batches.

## Helper

Use the scaffold when it saves time:

```bash
bash .claude/skills/superpowerz/scripts/new_plan.sh tmp/superpowerz/specs/YYYY-MM-DD-feature-slug.md
```

Default location:

`tmp/superpowerz/plans/YYYY-MM-DD-feature-slug.md`

## Minimum Plan Shape

Every plan should answer:

- what slice is first
- what file or symbol controls that slice
- what check can falsify the current hypothesis
- what makes the slice done

## Execution Handoff

Once the plan exists, execute one slice at a time.

After the first substantive edit, the next action should be focused validation when one exists.

Use `.claude/skills/executing-plans/SKILL.md` as the default execution workflow instead of ad hoc task hopping.

## Exit Condition

The plan is complete when the next implementation step is obvious, local, testable, and ready to be carried out by `.claude/skills/executing-plans/SKILL.md`.
