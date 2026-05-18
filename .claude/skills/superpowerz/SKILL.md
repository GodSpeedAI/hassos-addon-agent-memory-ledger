---
name: superpowerz
description: Local fallback entrypoint for the Superpowers plugin. Use when the user mentions Superpowers, the plugin is unavailable, or you need to route non-trivial engineering work in this repository into the local brainstorming, planning, debugging, and verification skills.
compatibility:
  tools:
    - read_file
    - grep_search
    - semantic_search
    - apply_patch
    - manage_todo_list
    - execution_subagent
    - run_in_terminal
---

# Superpowerz

This skill is the local entrypoint for the repository's Superpowers-style workflow.

It does not recreate marketplace packaging or automatic plugin hooks. It recreates the useful behavior with local skills and helper scripts that live in this repository.

## Instruction Priority

Follow instructions in this order:

1. Direct user instructions and repository instructions
2. This skill
3. Default assistant behavior

If repository guidance conflicts with this skill, prefer the repository guidance and adapt the workflow.

## What This Skill Does

Use this file as the routing layer when the plugin is unavailable or when you need to decide which local skill should govern the task.

The local suite is:

- `.claude/skills/using-superpowers/SKILL.md`
- `.claude/skills/brainstorming/SKILL.md`
- `.claude/skills/writing-plans/SKILL.md`
- `.claude/skills/executing-plans/SKILL.md`
- `.claude/skills/systematic-debugging/SKILL.md`
- `.claude/skills/verification-before-completion/SKILL.md`

If you are unsure where to start, start with `using-superpowers`.

## Routing Rules

### New feature or behavior change

1. Use `using-superpowers`.
2. Use `brainstorming`.
3. Use `writing-plans` after the design is clear.
4. Use `executing-plans` to carry out the slices.
5. Use `verification-before-completion` before any success claim.

### Bug, regression, or broken workflow

1. Use `using-superpowers`.
2. Use `systematic-debugging`.
3. Use `verification-before-completion` before any fix claim.

### Review or readiness check

1. Use `using-superpowers`.
2. If the task is checking whether work is complete or safe to land, use `verification-before-completion`.

## Shared Helpers

The local suite shares these helpers:

- `.claude/skills/superpowerz/scripts/new_spec.sh`
- `.claude/skills/superpowerz/scripts/new_plan.sh`
- `.claude/skills/superpowerz/scripts/new_worktree.sh`

They scaffold workflow artifacts under `tmp/superpowerz/`.

## Artifact Policy

Workflow artifacts are local working aids, not canonical project state.

Use them to make design intent, plan slices, and verification explicit. Only promote them into committed project documentation if the user asks or the task changes a persistent contract.

## Completion Standard

This meta skill is working as intended when it causes the next action to use the right focused skill rather than jumping directly into edits or unsupported completion claims.

## Quick Summary

For non-trivial work:

- design work: `brainstorming` -> `writing-plans` -> `executing-plans` -> `verification-before-completion`
- debug work: `systematic-debugging` -> execute -> `verification-before-completion`
- if unsure: `using-superpowers` first
