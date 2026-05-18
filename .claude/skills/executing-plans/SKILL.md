---
name: executing-plans
description: Use when a written plan exists and implementation should proceed in small validated slices. Carry out one plan slice at a time, keep scope tight, validate immediately after edits, and do not drift away from the approved plan without calling it out.
---

# Executing Plans

Use this skill after a design is clear and a plan exists.

This skill governs execution discipline. It is for carrying out the plan without wandering, batching unrelated edits, or claiming progress without evidence.

## Workflow

1. Read the current plan and select the next unfinished slice.
2. Identify the controlling file, symbol, or test for that slice.
3. Make the smallest edit that advances only that slice.
4. Run the narrowest available validation immediately after the first substantive edit.
5. If validation fails but stays within the same slice, repair locally and rerun the same validation.
6. Mark the slice complete only when the validation result supports it.
7. Move to the next slice only after the current slice is closed.

## Scope Rules

- Do not mix unrelated slices into one edit burst.
- Do not resume broad exploration between an edit and its first focused validation.
- Do not silently change the plan during execution. If the plan must change, say why and update the plan first.
- Prefer local, reversible edits over sweeping refactors.

## Validation Order

Prefer this order when more than one check is available:

1. behavior reproduction or failing scenario
2. narrow test for the touched slice
3. narrow compile, lint, or typecheck for the touched slice
4. broader fallback check

## Todo Discipline

Track slices in the todo tool while executing.

At any given time, exactly one slice should be in progress.

## Repository Reminder

While executing, preserve repository invariants and keep canonical history separate from derived state.

If a planned change would violate replayability, provenance, append-only integrity, or governance traceability, stop and revise the plan before editing.

## Exit Condition

Exit this skill only after the active slice has validation evidence and the next state is clear:

- continue with the next plan slice, or
- route into `.claude/skills/verification-before-completion/SKILL.md` for a completion claim
