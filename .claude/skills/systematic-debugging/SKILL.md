---
name: systematic-debugging
description: Use for bugs, regressions, failing tests, broken scripts, or mismatches between expected and actual behavior. Start from a concrete anchor, form one falsifiable local hypothesis, make a small grounded fix, and validate immediately.
---

# Systematic Debugging

Use this skill when behavior is wrong and you need to find the root cause instead of patching symptoms.

## Workflow

1. Start from the most concrete anchor available.
2. Read only enough nearby code to identify the controlling path.
3. Form one falsifiable local hypothesis.
4. Pick one cheap discriminating check.
5. Make the smallest grounded edit that tests the hypothesis.
6. Run focused validation immediately after the first substantive edit.
7. If the check fails, either repair the same slice or step one hop closer to the real controlling code.

## Guardrails

- Do not map the whole codebase before acting.
- Do not keep comparing many plausible paths once one path supports a real local hypothesis.
- Do not widen scope between the first edit and the first focused validation.
- Prefer root-cause fixes over output-only patches.

## Good Hypothesis Shape

The hypothesis should name:

- the nearby code path that controls the behavior
- the expected behavior
- why the current code fails to produce it
- the cheapest check that could prove the hypothesis wrong

## Exit Condition

Exit this skill only after fresh validation evidence shows the actual state of the bug or fix.

Before any success claim, route into `.claude/skills/verification-before-completion/SKILL.md`.
