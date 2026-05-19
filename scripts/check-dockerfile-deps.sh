#!/usr/bin/env bash
# check-dockerfile-deps.sh — CI gate for Dockerfile dependency hygiene
#
# Fails when:
#   1. A Dockerfile contains an unapproved :latest tag
#   2. A Dockerfile contains --allow-untrusted without a justification comment
#   3. requirements-bridge.txt has a line without an exact == pin
#
# Approved exceptions are listed in the arrays below.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

# ── Configuration ──────────────────────────────────────────────────────────

# Approved :latest occurrences: "relative/path:line_number"
# Each entry must have a corresponding justification comment in the file.
APPROVED_LATEST=(
	"agent_memory_ledger/docker-dependencies/timescaledb-tools:11"
	"agent_memory_ledger/Dockerfile:17"
)

# ── Check 1: Unapproved :latest tags ──────────────────────────────────────

echo "=== Check 1: Unapproved :latest tags in Dockerfiles ==="

# Find all Dockerfiles and dependency files
DOCKERFILES=()
while IFS= read -r -d '' f; do
	DOCKERFILES+=("$f")
done < <(find "$REPO_ROOT" -name "Dockerfile" -print0 2>/dev/null)
while IFS= read -r -d '' f; do
	DOCKERFILES+=("$f")
done < <(find "$REPO_ROOT/agent_memory_ledger/docker-dependencies" -type f -print0 2>/dev/null)

for file in "${DOCKERFILES[@]}"; do
	rel="${file#"$REPO_ROOT/"}"

	# Look for :latest tags (but not in comments)
	while IFS= read -r line; do
		lineno="$(echo "$line" | cut -d: -f1)"
		content="$(echo "$line" | cut -d: -f2-)"
		# Skip comment lines
		trimmed="$(echo "$content" | sed 's/^[[:space:]]*//')"
		if [[ "$trimmed" == \#* ]]; then
			continue
		fi
		if echo "$content" | grep -qE ':[0-9a-zA-Z._-]*latest([[:space:]]|$|"|\x27)'; then
			# Check if this specific occurrence is approved
			key="${rel}:${lineno}"
			is_approved=false
			for approved in "${APPROVED_LATEST[@]}"; do
				if [[ "$key" == "$approved" ]]; then
					is_approved=true
					break
				fi
			done

			if [[ "$is_approved" == "true" ]]; then
				echo "  [OK] $rel:$lineno (approved exception)"
			else
				echo "  [FAIL] $rel:$lineno — unapproved :latest tag"
				echo "         Line: $content"
				FAILED=1
			fi
		fi
	done < <(grep -n "latest" "$file" 2>/dev/null || true)
done

# ── Check 2: --allow-untrusted without justification ──────────────────────

echo ""
echo "=== Check 2: --allow-untrusted without justification ==="

for file in "${DOCKERFILES[@]}"; do
	rel="${file#"$REPO_ROOT/"}"

	while IFS= read -r line; do
		lineno="$(echo "$line" | cut -d: -f1)"
		content="$(echo "$line" | cut -d: -f2-)"

		if echo "$content" | grep -q "\-\-allow-untrusted"; then
			# Check if there's a justification comment within 10 lines above
			start=$((lineno - 10))
			if [ "$start" -lt 1 ]; then
				start=1
			fi
			has_justification=false
			above=$(sed -n "${start},${lineno}p" "$file")
			if echo "$above" | grep -qi "allow-untrusted justification\|justification.*allow-untrusted"; then
				has_justification=true
			fi

			if [[ "$has_justification" == "true" ]]; then
				echo "  [OK] $rel:$lineno (justified)"
			else
				echo "  [FAIL] $rel:$lineno — --allow-untrusted without justification comment"
				echo "         Line: $content"
				FAILED=1
			fi
		fi
	done < <(grep -n "\-\-allow-untrusted" "$file" 2>/dev/null || true)
done

# ── Check 3: Python dependency pins ───────────────────────────────────────

echo ""
echo "=== Check 3: Python requirements exact pins ==="

REQ_FILE="$REPO_ROOT/agent_memory_ledger/requirements-bridge.txt"
if [ -f "$REQ_FILE" ]; then
	rel="${REQ_FILE#"$REPO_ROOT/"}"
	while IFS= read -r line; do
		lineno="$(echo "$line" | cut -d: -f1)"
		content="$(echo "$line" | cut -d: -f2-)"
		# Skip comments and blank lines
		trimmed="$(echo "$content" | sed 's/^[[:space:]]*//')"
		if [[ -z "$trimmed" ]] || [[ "$trimmed" == \#* ]]; then
			continue
		fi
		# Check for exact pin (==)
		if ! echo "$content" | grep -qE '==[0-9]'; then
			echo "  [FAIL] $rel:$lineno — missing exact pin (==)"
			echo "         Line: $content"
			FAILED=1
		else
			echo "  [OK] $rel:$lineno"
		fi
	done < <(grep -n "." "$REQ_FILE")
else
	echo "  [WARN] $REQ_FILE not found — skipping Python pin check"
fi

# ── Result ─────────────────────────────────────────────────────────────────

echo ""
if [ "$FAILED" -ne 0 ]; then
	echo "RESULT: FAILED — fix the issues above before merging"
	exit 1
else
	echo "RESULT: PASSED — all dependency checks clean"
	exit 0
fi
