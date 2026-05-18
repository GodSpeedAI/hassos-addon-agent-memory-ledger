---
name: using-superpowers
description: Use when starting non-trivial engineering work in this repository, when the user mentions Superpowers, or when the plugin is unavailable and you need to route the task into the local skill suite before acting.
---

# Using Superpowers

This skill is the front door to the local Superpowerz workflow.

Its job is not to do the work itself. Its job is to choose the right workflow skill before edits, debugging, or completion claims.

## Instruction Priority

Follow instructions in this order:

1. Direct user instructions and repository instructions
2. The selected local Superpowerz skill
3. Default assistant behavior

## Rule

If the task is more than a quick factual answer, route it before acting.

Do not jump directly into code changes or broad exploration if one of the local workflow skills clearly applies.

## Routing Table

### New behavior, feature work, refactor with design choices

Use `.claude/skills/brainstorming/SKILL.md` first.

After the design is clear or approved, use `.claude/skills/writing-plans/SKILL.md`.

When the plan is ready, use `.claude/skills/executing-plans/SKILL.md`.

### Bug, regression, failed validation, unexpected behavior

Use `.claude/skills/systematic-debugging/SKILL.md` first.

### About to claim success, completion, or readiness

Use `.claude/skills/verification-before-completion/SKILL.md` first.

### Explicit Superpowerz request or uncertainty about the right track

Use `.claude/skills/superpowerz/SKILL.md` as the index, then choose the focused skill.

## Quick Decision Test

Ask:

1. Is this a design problem?
2. Is this a debugging problem?
3. Am I about to claim something is complete or fixed?

Use the matching skill as soon as one answer is yes.

## Repository Reminder

This repository prioritizes correctness, replayability, provenance, and append-only integrity over speed.

The workflow you pick must preserve `canonical_history != derived_state`.
