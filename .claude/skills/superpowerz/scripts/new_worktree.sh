#!/usr/bin/env bash
set -euo pipefail

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "This helper must run inside a git worktree." >&2
    exit 1
fi

ROOT_DIR=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "${ROOT_DIR}")
SLUG=${1:-task}
BRANCH_NAME="sp/${SLUG}"
PARENT_DIR="${ROOT_DIR%/*}"
if [ -z "${PARENT_DIR}" ] || [ "${PARENT_DIR}" = "/" ]; then
    TARGET_DIR="/${REPO_NAME}-${SLUG}"
else
    TARGET_DIR="${PARENT_DIR}/${REPO_NAME}-${SLUG}"
fi

if git show-ref --verify --quiet "refs/heads/${BRANCH_NAME}"; then
    git worktree add "${TARGET_DIR}" "${BRANCH_NAME}"
else
    git worktree add -b "${BRANCH_NAME}" "${TARGET_DIR}"
fi

printf '%s\n' "${TARGET_DIR}"
