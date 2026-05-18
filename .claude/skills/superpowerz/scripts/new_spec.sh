#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
DATE_STAMP=$(date +%F)
SLUG=${1:-task}
TITLE=${2:-${SLUG//-/ }}
SPEC_DIR="${ROOT_DIR}/tmp/superpowerz/specs"
SPEC_PATH="${SPEC_DIR}/${DATE_STAMP}-${SLUG}.md"

mkdir -p "${SPEC_DIR}"

cat > "${SPEC_PATH}" <<EOF
# ${TITLE}

## Goal
- Describe the user-visible outcome.

## Current Context
- Relevant files, symbols, tests, or failing behavior.

## Constraints And Invariants
- Repository or user constraints that must remain true.

## Recommended Approach
- The chosen approach and why it is the best fit here.

## Alternatives Considered
- Approach 1:
- Approach 2:

## Acceptance Checks
- Command:
- Expected result:

## Open Questions
- None yet.
EOF

printf '%s\n' "${SPEC_PATH}"
