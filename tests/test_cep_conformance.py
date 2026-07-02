"""CEP-0008 conformance (LE-03): v1 is a valid profile of the semantic envelope.

`contracts/sea.agent.event.v1.json` stays the enforced runtime shape; CEP-0008
stays the conceptual canon. The CEP-0008 profile schema and its v1 fixtures are
**vendored** into `tests/fixtures/cep/` (pinned by sha256 in
`contracts/CONTRACTS_VERSION`), so this test is self-contained — it no longer
depends on a `../cep` sibling checkout (WP-2, F-12).

Drift checks below fail if a vendored copy is edited by a single byte or falls
out of sync with the pin.
"""

import copy
import hashlib
import json
import os

import jsonschema
import pytest

_LEDGER_CONTRACTS_DIR = os.path.join(
    os.path.dirname(__file__),
    "..",
    "agent_memory_ledger",
    "rootfs",
    "usr",
    "share",
    "agent_memory_ledger",
    "contracts",
)
# Vendored CEP-0008 profile + fixtures (no sibling-checkout dependency).
_CEP_VENDORED_DIR = os.path.join(os.path.dirname(__file__), "fixtures", "cep")
_CEP_SCHEMA_PATH = os.path.join(_CEP_VENDORED_DIR, "semantic-envelope.schema.json")
_CEP_FIXTURES_DIR = _CEP_VENDORED_DIR

# Pinned sha256 hashes — the single source of truth is
# `contracts/CONTRACTS_VERSION`. Editing a vendored copy by one byte fails here.
_PIN = {
    "v1": "d2a245183f7a52672dec11d7a8e9236d3db78dac674ab066d944fb758443e195",
    "cep_semantic_envelope": "a2b2722006e62551d89f6c8d28a49b398d886f41cfd27aafb19e1106d79162eb",
    "v1-minimal": "b7985a23bda37d333e49e492c31a8920f11979b5d26870c3fd57e2bf019ec17d",
    "v1-full": "7ce760d3c8e331e0c414f182f80c77a51cc33d9b426e03a9766f5d2c259d0270",
    "v1-authority-decision": "e35b67d19b00586601f35560d01d76529ecccb12513ba9e5b4ea4f8b70a9f7dc",
}


def _sha256(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


@pytest.fixture
def v1_schema():
    with open(os.path.join(_LEDGER_CONTRACTS_DIR, "sea.agent.event.v1.json")) as f:
        return json.load(f)


@pytest.fixture
def cep_semantic_envelope_schema():
    with open(_CEP_SCHEMA_PATH) as f:
        return json.load(f)


@pytest.fixture(params=["v1-minimal.json", "v1-full.json", "v1-authority-decision.json"])
def cep_v1_fixture(request):
    with open(os.path.join(_CEP_FIXTURES_DIR, request.param)) as f:
        return json.load(f)


class TestContractPinDrift:
    """WP-2 drift checks: vendored copies must be byte-identical to the pin.
    Editing any vendored copy by a single byte fails here (the contract's
    teeth). These run unconditionally — no sibling checkout required."""

    def test_v1_schema_matches_pin(self):
        assert _sha256(
            os.path.join(_LEDGER_CONTRACTS_DIR, "sea.agent.event.v1.json")
        ) == _PIN["v1"], "ledger v1 schema drifted from CONTRACTS_VERSION pin"

    def test_cep_semantic_envelope_matches_pin(self):
        assert _sha256(_CEP_SCHEMA_PATH) == _PIN["cep_semantic_envelope"], (
            "vendored CEP semantic-envelope schema drifted from pin"
        )

    @pytest.mark.parametrize(
        "name,pinkey",
        [
            ("v1-minimal.json", "v1-minimal"),
            ("v1-full.json", "v1-full"),
            ("v1-authority-decision.json", "v1-authority-decision"),
        ],
    )
    def test_cep_fixture_matches_pin(self, name, pinkey):
        assert _sha256(os.path.join(_CEP_FIXTURES_DIR, name)) == _PIN[pinkey], (
            f"vendored CEP fixture {name} drifted from pin"
        )


class TestCepConformance:
    """Real v1 fixtures (owned by the CEP repo, not invented here) validate
    against both v1's own schema and the CEP-0008 semantic envelope profile."""

    def test_fixture_is_a_real_v1_instance(self, v1_schema, cep_v1_fixture):
        jsonschema.validate(cep_v1_fixture, v1_schema)

    def test_fixture_validates_as_semantic_envelope(
        self, cep_semantic_envelope_schema, cep_v1_fixture
    ):
        jsonschema.validate(cep_v1_fixture, cep_semantic_envelope_schema)


class TestCepConformanceHasTeeth:
    """The conformance test must check substance, not just file existence."""

    def test_missing_provenance_fails_both_v1_and_cep(
        self, v1_schema, cep_semantic_envelope_schema, cep_v1_fixture
    ):
        # WP-6 (F-06): provenance is now required in v1 (the contract flip),
        # matching the CEP-0008 profile. A provenance-less envelope fails BOTH
        # schemas — the v1↔CEP-profile strictness gap is closed.
        stripped = copy.deepcopy(cep_v1_fixture)
        del stripped["provenance"]

        with pytest.raises(jsonschema.ValidationError, match="provenance"):
            jsonschema.validate(stripped, v1_schema)
        with pytest.raises(jsonschema.ValidationError, match="provenance"):
            jsonschema.validate(stripped, cep_semantic_envelope_schema)

    def test_missing_provenance_origin_fails_cep(
        self, cep_semantic_envelope_schema, cep_v1_fixture
    ):
        stripped = copy.deepcopy(cep_v1_fixture)
        stripped["provenance"].pop("origin", None)

        with pytest.raises(jsonschema.ValidationError, match="origin"):
            jsonschema.validate(stripped, cep_semantic_envelope_schema)
