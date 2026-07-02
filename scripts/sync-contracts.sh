#!/usr/bin/env bash
# WP-2 (F-12): sync the canonical v1 schema from the ledger (source of truth)
# into every consumer repo's vendored location, then recompute + print sha256
# so the pin in contracts/CONTRACTS_VERSION and each consumer's drift-check
# test can be updated together.
#
# Usage: scripts/sync-contracts.sh [--check]   (default: copy; --check: verify)
#
# This script does NOT edit the pinned hashes in test files automatically —
# after running it, diff the printed hashes against CONTRACTS_VERSION and
# update any that changed, deliberately, in the same commit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECTS="$(cd "$ROOT/.." && pwd)"
LEDGER_CONTRACTS="$ROOT/agent_memory_ledger/rootfs/usr/share/agent_memory_ledger/contracts"
V1="sea.agent.event.v1.json"

declare -A CONSUMERS=(
  ["$PROJECTS/SEA/libs/agentic-capability-loop/tests/fixtures"]=1
  ["$PROJECTS/godspeed_agent/agentic_capability_loop/tests/fixtures"]=1
  ["$PROJECTS/SWE_SEED/tests/fixtures"]=1
  ["$PROJECTS/edgeai/tests/fixtures"]=1
  ["$PROJECTS/cep/schemas/vendored"]=1
)

MODE="${1:-copy}"

src="$LEDGER_CONTRACTS/$V1"
if [[ ! -f "$src" ]]; then
  echo "canonical v1 schema not found at $src" >&2
  exit 1
fi

canonical_hash=$(sha256sum "$src" | awk '{print $1}')
echo "canonical ($V1): $canonical_hash"
echo "source: $src"
echo

mismatch=0
for dest_dir in "${!CONSUMERS[@]}"; do
  dest="$dest_dir/$V1"
  if [[ "$MODE" == "--check" ]]; then
    if [[ ! -f "$dest" ]]; then
      echo "MISSING: $dest"; mismatch=1; continue
    fi
    h=$(sha256sum "$dest" | awk '{print $1}')
    if [[ "$h" != "$canonical_hash" ]]; then
      echo "DRIFT:   $dest ($h)"; mismatch=1
    else
      echo "OK:      $dest"
    fi
  else
    mkdir -p "$dest_dir"
    cp "$src" "$dest"
    echo "COPIED:  $dest"
  fi
done

echo
echo "If any hashes changed, update contracts/CONTRACTS_VERSION and each"
echo "consumer's drift-check test pin in the same commit."
[[ "$mismatch" -eq 0 ]] || exit 1
