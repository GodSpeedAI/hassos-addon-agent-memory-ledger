# CEP-0008 conformance

`sea.agent.event.v1.json` (this directory) is proven, by
`tests/test_cep_conformance.py`, to be a valid profile of CEP-0008's Semantic
Envelope.

**WP-2 (F-12):** the CEP-0008 profile schema and its v1 fixtures are **vendored**
into `tests/fixtures/cep/` and pinned by sha256 in `CONTRACTS_VERSION`. The
conformance test no longer depends on a `../cep` sibling checkout — it runs
self-contained in any environment that checks out only this repo. Drift checks
in `TestContractPinDrift` fail if any vendored copy is edited by a single byte
or falls out of sync with the pin.

The canonical sources remain:
- v1 wire schemas: this `contracts/` directory (the enforcement point).
- CEP-0008 profile + mapping: the CEP repo (`schemas/semantic-envelope.schema.json`,
  `schemas/semantic-envelope.mapping.md`).

This repo's v1 schema is unchanged by that mapping — CEP-0008 stays the
conceptual canon, v1 stays the enforced runtime shape. As of WP-6 (F-06), v1
**requires** `provenance` — the v1↔CEP-profile strictness gap is closed: both
the schema and the bridge's `_ENVELOPE_REQUIRED` enforce it, and every emitter
(SEA, godspeed_agent, SWE_SEED, edgeai) populates it. The retired "epistemic
envelope" concept is exactly this `provenance` block (origin + chain). See the
mapping doc's "Open gap" note for the one CEP-0008 distinction (SS52 scope /
boundary_record / completeness_status / omission_status) this profile does not
attempt to close.

Re-sync procedure: update the canonical file in its source repo, recompute its
sha256, update the pin in `CONTRACTS_VERSION`, copy the new file into
`tests/fixtures/cep/` (and into each consumer's `contracts/vendored/`), and
update the pinned hash in every consumer's drift-check test.
