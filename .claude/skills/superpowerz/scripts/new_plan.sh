#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
DATE_STAMP=$(date +%F)
SPEC_INPUT=${1:-}

if [[ -n "${SPEC_INPUT}" ]]; then
    SPEC_BASENAME=$(basename "${SPEC_INPUT}")
    SLUG=${SPEC_BASENAME#????-??-??-}
    SLUG=${SLUG%.md}
else
    SLUG=task
fi

PLAN_DIR="${ROOT_DIR}/tmp/superpowerz/plans"
PLAN_PATH="${PLAN_DIR}/${DATE_STAMP}-${SLUG}.md"

mkdir -p "${PLAN_DIR}"

cat > "${PLAN_PATH}" <<EOF
# Implementation Plan: ${SLUG}

## Inputs
- Spec: ${SPEC_INPUT:-not provided}

## Task Slices
1. Identify the controlling code path and nearest validation.
2. Make the first small edit for the active slice.
3. Run the narrowest validation immediately.
4. Repair locally if validation exposes a defect.
5. Repeat for the next slice only after the current slice is green.

## Expected File Touches
- List exact files once known.

## Validation Commands
- Slice 1:
- Slice 2:

## Risks
- Behavior regression:
- Invariant risk:

## Exit Criteria
- Requested behavior is implemented.
- Focused validation has run successfully.
- Remaining risks are called out explicitly.
EOF

printf '%s\n' "${PLAN_PATH}"
