# Implementation Plan — agent-memory-ledger: Contract Hardening for Production Ingestion

**Created:** 2026-07-01

**Source of truth:** `SEA/.agents/reports/syntelligent_infrastructure.md` §7
Integration Seam Audit (rows "godspeed_agent → agent-memory-ledger", "edgeai →
agent-memory-ledger", "SEA → agent-memory-ledger"), §9 Loose Ends LE-01,
LE-03, LE-07, LE-08, §13 WP-1/WP-2. Quote it, don't paraphrase from memory.

**Originating context:** Cross-repo canonicalization audit (read-only, no
source changes made during the audit itself) found that this repo's v1
contract schemas are already the correct, enforced convergence target for the
whole ecosystem — the problem is entirely on the *producer* side (SEA,
SWE_SEED, godspeed_agent, edgeai all emit a non-conformant envelope shape).
This plan's job is **not** to change the contract — it's to hardens this
repo's role as the fixed point other repos converge on, and to prove the
convergence works end-to-end once producers catch up.

**Status of the work today:** `contracts/sea.agent.event.v1.json` (and
sibling `sea.governance.decision.v1.json`, `sea.governance.request.v1.json`,
`sea.memory.write.v1.json`, `sea.memory.lifecycle.v1.json`) already exist,
are already enforced (`additionalProperties: false`), and are already the
target every other repo's plan converges toward. What's missing here is (a)
an end-to-end ingest test that proves a *conformant* v1 event round-trips to
Postgres with zero DLQ, (b) a CEP-0008 conformance declaration once CEP ships
its schema, and (c) confidence that the DLQ path is exercised and observable,
not just theoretically present.

---

## 0. How to use this plan (agent operating instructions)

- Tasks 1, 2, 3 are independent of each other; execute in any order.
- **Every task ends with a verification gate.** Do not mark a task done until
  its gate command exits 0.
- **Core principle: this repo defines the contract, it does not chase
  producers.** Do not loosen `additionalProperties: false` or add fields to
  accommodate a producer's current (non-conformant) shape — that direction of
  change belongs in the producer repos' plans (SEA, SWE_SEED, godspeed_agent,
  edgeai), not here. If a task in this plan tempts you to relax a schema,
  stop — that's scope creep into a different plan.
- Match surrounding code style; locate the relevant idioms in
  `agent_memory_ledger/rootfs/usr/bin/sea_nats_bridge.py` (the two-stage
  contract gate: envelope schema, then payload) and `contracts/*.v1.json`
  (schema authoring style — draft 2020-12, explicit `additionalProperties:
  false`, `enum` where the domain is closed).
- The `contracts/*.v1.json` files are the source of truth for wire shape —
  change them only in the same commit as a producer migration that needs a
  genuinely new field, never to paper over a bug.

### Global verification gates (must stay green after EVERY task)

```bash
cd /home/sprime01/projects/hassos-addon-agent-memory-ledger
pytest                                   # full contract + bridge test suite
python -m json.tool agent_memory_ledger/rootfs/usr/share/agent_memory_ledger/contracts/sea.agent.event.v1.json >/dev/null   # schema itself is valid JSON
```

No rebuild step needed — this repo has no generated-code layer in the
affected paths.

---

## Key facts already discovered (do not re-derive)

| Thing | Location |
|---|---|
| v1 agent-event envelope schema (the convergence target for all producers) | `agent_memory_ledger/rootfs/usr/share/agent_memory_ledger/contracts/sea.agent.event.v1.json` |
| Sibling v1 contracts (governance decision/request, memory write/lifecycle) | `agent_memory_ledger/rootfs/usr/share/agent_memory_ledger/contracts/sea.governance.{decision,request}.v1.json`, `sea.memory.{write,lifecycle}.v1.json` |
| The bridge that ingests from NATS and enforces the two-stage gate (envelope schema, then payload) | `agent_memory_ledger/rootfs/usr/bin/sea_nats_bridge.py` |
| Required fields on the v1 envelope | `schema_version` (const `"v1"`), `event_id` (uuid), `source_agent`, `occurred_at`, `payload` |
| Why `additionalProperties: false` matters | it is *why* family-A envelopes (from SEA/SWE_SEED/godspeed_agent) currently fail ingestion and DLQ — this is intentional fail-closed behavior, not a bug to fix here |
| DLQ destination on schema-validation failure | subject `sea.ledger.deadletter` (per report §11 persistence-flow diagram) |
| README description of this repo's role | "records governance decisions, it does not make them" — do not add decision logic here, only persistence/validation |

---

## Task 1 — Prove a conformant v1 event round-trips end-to-end with zero DLQ

**Goal:** A test publishes a fully conformant `sea.agent.event.v1.json`
message to the ingest path and asserts it lands in Postgres with no DLQ
entry — the acceptance criterion WP-1 names for the whole ecosystem, owned
here since this repo is the terminal consumer.

**Why this shape:** WP-1's stated acceptance is "a loop `WorkRequested`→
`SettlementRecorded` chain persists to Postgres with zero DLQ." That chain
can't be tested for real until producer repos migrate (see their plans), but
this repo can and should prove its *half* of the contract in isolation now,
so producer-repo migrations have a green target to converge on and a fast
feedback loop that doesn't require the whole ecosystem running.

### Steps

1. Locate (or add if absent) the ingest/bridge test directory — likely
   alongside existing contract tests referenced by `pytest`. Find the
   existing test pattern for `sea_nats_bridge.py` — grep the repo for
   `sea_nats_bridge` in test files to find the current harness.
2. Add a fixture event that is a fully valid instance of
   `sea.agent.event.v1.json` (all required fields, realistic `source_agent`
   and `payload`).
3. Assert: (a) schema validation passes, (b) the row appears in the
   `event_log`/equivalent table (or the equivalent in-process sink the test
   harness uses), (c) no DLQ entry is produced.
4. Add a negative-companion assertion in the same test module (not a new
   task): publish a family-A-shaped event (`{event_id, event_type, namespace,
   occurred_at, payload}` — no `schema_version`) and assert it is rejected
   and DLQ'd, proving the gate has teeth on the exact failure mode the audit
   found live in production today.

### Gate

```bash
cd /home/sprime01/projects/hassos-addon-agent-memory-ledger
pytest -k "agent_event_v1 or ingest" -v
```

**Done when:** both the positive (conformant → Postgres, zero DLQ) and
negative (family-A shape → DLQ, not silently dropped or silently accepted)
assertions pass. Deliberately mutating the fixture to violate
`additionalProperties: false` (add a stray top-level key) must make the
positive-path assertion fail — proving the test actually exercises schema
enforcement, not just a happy-path stub.

**Redesign trigger:** none plausible — this is a pure test-hardening task
against an existing, unchanged contract.

---

## Task 2 — Declare v1 a conformant profile of CEP-0008 once CEP ships its schema

**Goal:** Once `cep/schemas/semantic-envelope.schema.json` exists (produced
by the CEP repo's plan, task 1), this repo has an automated test proving the
v1 contract's field set is a valid subset/profile of the CEP-0008 semantic
envelope, closing LE-03's "canon is prose, not enforceable" gap from this
side.

**Why this shape:** The audit's recommendation (§6) is explicitly "do not
force one wire format everywhere... define one JSON Schema profile of
[CEP-0008] that equals the flat v1 contract" — this repo's v1 schema stays
the enforced runtime shape; CEP-0008 stays the conceptual canon; this task
is the *proof* they're the same thing, not a migration of either.

**Prerequisite:** CEP repo plan task 1 (ships `semantic-envelope.schema.json`)
must land first — if it hasn't, skip this task for now and revisit; do not
invent a schema shape on this repo's side to unblock yourself.

### Steps

1. Once available, copy or reference (do not vendor a stale copy —
   reference by relative path if CEP is a sibling checkout, or vendor with a
   version-pin comment noting the CEP commit/tag it was copied from) `cep/schemas/semantic-envelope.schema.json`.
2. Write a conformance test: take 2-3 real fixture instances of
   `sea.agent.event.v1.json` and validate them against the CEP-0008 schema
   (or the mapping/subset logic the CEP schema defines for "profiles").
3. Document the mapping in a short comment or adjacent doc file next to
   `contracts/sea.agent.event.v1.json` — which CEP-0008 concepts (state,
   evidence, settlement, authority, provenance) correspond to which v1 fields
   (`payload`, `provenance`, `event_type`).

### Gate

```bash
cd /home/sprime01/projects/hassos-addon-agent-memory-ledger
pytest -k "cep_conformance or semantic_envelope" -v
```

**Done when:** the conformance test passes for real v1 fixtures, and fails
if a fixture is mutated to violate a CEP-0008-required distinction (e.g.
strip `provenance` if CEP-0008 requires it) — proving the test checks
substance, not just "file exists."

**Redesign trigger:** if CEP-0008's schema turns out to require fields v1
structurally cannot represent without breaking `additionalProperties: false`,
stop and escalate to a cross-repo contract decision — do not silently loosen
v1's schema to fit. That decision is above this plan's scope.

---

## Task 3 — Verify DLQ replay is observable and testable, not just theoretically present

**Goal:** An operator (or an automated test) can prove that a message
rejected to `sea.ledger.deadletter` is inspectable and replayable after a
producer fixes its shape — closing the "silent data loss to DLQ" failure
mode LE-01 names as the risk of leaving this unaddressed.

**Why this shape:** LE-01's stated failure symptom if ignored is "silent data
loss to DLQ." A schema gate that fails closed is correct, but only mitigates
the risk if DLQ contents are visible and replayable — otherwise fail-closed
just becomes silent data loss with extra steps.

### Steps

1. Find the current DLQ consumer/inspection path (search for
   `sea.ledger.deadletter` usage across the repo).
2. If no replay/inspection tool exists, add a minimal one: a script or test
   utility that subscribes to `sea.ledger.deadletter`, prints/logs the
   rejected envelope and the validation error that caused rejection.
3. Add a test: publish a non-conformant event, assert it appears on the DLQ
   subject with its original payload intact and a machine-readable rejection
   reason attached.

### Gate

```bash
cd /home/sprime01/projects/hassos-addon-agent-memory-ledger
pytest -k "dlq" -v
```

**Done when:** the DLQ test proves both that a bad event lands on
`sea.ledger.deadletter` *and* that the rejection reason is present and
correct (e.g. asserts the error message names the missing/violating field) —
not just that the subject received a message.

**Redesign trigger:** none plausible.

---

## Final acceptance checklist (whole plan)

- [ ] A conformant v1 event round-trips to Postgres with zero DLQ; a
      non-conformant (family-A) event is rejected and DLQ'd — both proven by
      test, both with a negative/teeth check. *(Task 1)*
- [ ] v1 is proven, by an automated conformance test, to be a valid profile
      of CEP-0008 once CEP's schema ships. *(Task 2)*
- [ ] DLQ contents are inspectable/replayable and a test proves the
      rejection reason is captured, not just the fact of rejection. *(Task 3)*
- [ ] All global gates green (`pytest`, schema JSON validity).
- [ ] No change was made to `additionalProperties: false` or to loosen any
      existing v1 contract's required-field set.

## Guardrails (do not violate)

- Do not relax any `contracts/*.v1.json` schema to accommodate a producer's
  current non-conformant shape — the producers converge to this repo, not
  the reverse.
- Do not add governance decision logic here — this repo's stated job is
  "records governance decisions, it does not make them."
- Keep Task 2 out of the critical path if CEP hasn't shipped its schema yet
  — do not block Tasks 1 and 3 on it.
- Commit hygiene: Task 1, 2, 3 are independent — keep them in separate
  commits so a partial CEP dependency (Task 2) doesn't block landing 1 and 3.
