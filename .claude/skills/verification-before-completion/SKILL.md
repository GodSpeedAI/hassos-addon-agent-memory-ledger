---
name: verification-before-completion
description: Use when about to claim something is fixed, complete, passing, reviewed, or ready. Require fresh command output and report the observed result rather than the intended result.
---

# Verification Before Completion

Evidence before claims.

## Rule

Do not claim success without fresh verification that directly supports the claim.

## Gate

Before saying work is done, fixed, clean, or ready:

1. Identify the narrowest command that proves the claim.
2. Run it fresh.
3. Read the output and exit code.
4. Report what happened.

## Good Examples

- `bash -n path/to/script.sh` succeeded.
- `pytest tests/check_release_installability.py -q` passed.
- `get_errors` still reports these files.

## Bad Examples

- should be fixed now
- looks good
- probably passes

## Scope Rule

Prefer the most behavior-scoped check available:

1. failing behavior reproduction
2. narrow test
3. narrow compile or lint check
4. broader fallback check

`git diff` is not a substitute for executable validation when executable validation exists.

## Exit Condition

Completion language is allowed only after the verification step has been run and its output actually supports the claim.
