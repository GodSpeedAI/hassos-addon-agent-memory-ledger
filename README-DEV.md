# Local Development

Agent Memory Ledger is a local-first governance substrate for SEA Forge and
ZeroClaw. Development involves PostgreSQL extensions, a Python NATS bridge
worker, SQL schema migrations, and Home Assistant add-on packaging.

## Running Tests

### Prerequisites

```bash
pip install -r tests/requirements-test.txt
```

### Run All Unit Tests

```bash
python -m pytest tests/ -v
```

### Run Specific Test Modules

```bash
# Subject routing and canonical mapping
python -m pytest tests/test_subject_routing.py -v

# Event envelope validation (contract)
python -m pytest tests/test_envelope_validation.py -v

# Bridge core logic (inbound, outbound, idempotency, transactions)
python -m pytest tests/test_bridge.py -v

# Health endpoints (/healthz, /readyz, /metrics-lite)
python -m pytest tests/test_health.py -v

# SQL schema smoke tests and least-privilege grants
python -m pytest tests/test_sql_schema.py -v

# Bridge configuration loading
python -m pytest tests/test_config.py -v
```

### Run with Markers

```bash
# Only unit tests (no external dependencies)
python -m pytest tests/ -v -m unit
```

### Lint Python

```bash
pip install ruff
ruff check agent_memory_ledger/rootfs/usr/bin/sea_nats_bridge.py tests/
```

### Test Coverage

The test suite covers 168 tests across 6 modules:

| Module                        | Tests | Coverage area                                                                         |
| ----------------------------- | ----- | ------------------------------------------------------------------------------------- |
| `test_subject_routing.py`     | 21    | Subject family extraction, canonical route mapping, message ID derivation             |
| `test_envelope_validation.py` | 47    | Envelope validation, payload validation, contract validation, fail-open/fail-closed   |
| `test_bridge.py`              | 17    | Inbound processing, idempotency (inbox + outbox), transactionality, outbound dispatch |
| `test_health.py`              | 15    | `/healthz`, `/readyz`, `/metrics-lite`, HTTP routing                                  |
| `test_sql_schema.py`          | 55    | SQL schema smoke tests, least-privilege role grants, constraint validation            |
| `test_config.py`              | 5     | BridgeConfig defaults, env loading, DSN construction                                  |

All tests are pure unit tests using mocks — no PostgreSQL or NATS required.

### CI Integration

The `test-bridge` CI job runs on every push and PR:

1. Sets up Python 3.12
2. Installs test dependencies
3. Runs `ruff check` on bridge source and tests
4. Runs `pytest`

The build job gates on `test-bridge` passing.

## SEA Forge Bridge Smoke Test

`scripts/smoke_sea_bridge.sh` is an end-to-end smoke test that publishes
messages to NATS, waits for the bridge to ingest them, then verifies the data
landed in the correct PostgreSQL canonical tables and that the health endpoint
reports readiness.

### What It Does

1. Validates required tools (`nats` CLI, `psql`, `jq`, `curl`)
2. Validates environment variables for NATS and PostgreSQL connections
3. Creates a smoke-test identity in `governance.identities` (needed for FK
   constraint on `governance.action_requests`)
4. Publishes a valid `sea.agent.event.smoke.test` message
5. Publishes a valid `sea.governance.request.tool_call` message
6. Waits for bridge ingestion (configurable, default 5 seconds)
7. Queries `event_log.inbox_events`, `event_log.agent_events`, and
   `governance.action_requests` for the test data
8. Calls `/readyz` and `/healthz` on the health endpoint
9. Prints PASS/FAIL with specific reasons for each check

The script is non-destructive: it only INSERTs test data tagged with a unique
prefix. It does not DROP, TRUNCATE, or ALTER anything. Cleanup SQL is printed
at the end.

### Required Tools

| Tool   | Required | Notes                                          |
| ------ | -------- | ---------------------------------------------- |
| `psql` | Yes      | PostgreSQL client                              |
| `jq`   | Yes      | JSON processing                                |
| `curl` | Yes      | Health endpoint checks                         |
| `nats` | No       | NATS CLI — publish steps are skipped if absent |

### Environment Variables

| Variable           | Required | Example                                                            |
| ------------------ | -------- | ------------------------------------------------------------------ |
| `NATS_URL`         | Yes      | `nats://127.0.0.1:4222`                                            |
| `PGHOST`           | Yes      | `127.0.0.1`                                                        |
| `PGPORT`           | Yes      | `5432`                                                             |
| `PGDATABASE`       | Yes      | `agent_memory`                                                     |
| `PGUSER`           | Yes      | `bridge_worker`                                                    |
| `PGPASSWORD`       | Yes      | your-password                                                      |
| `HEALTH_URL`       | Yes      | `http://127.0.0.1:8099`                                            |
| `SMOKE_WAIT`       | No       | Seconds to wait (default: `5`)                                     |
| `PG_SUPERUSER`     | No       | For identity setup if PGUSER lacks INSERT on governance.identities |
| `PG_SUPERPASSWORD` | No       | Password for PG_SUPERUSER                                          |

### Running from a Dev Machine

Requires a running NATS server with JetStream, PostgreSQL with the agent_memory
schema applied, and the SEA Forge bridge running.

```bash
export NATS_URL="nats://127.0.0.1:4222"
export PGHOST="127.0.0.1"
export PGPORT="5432"
export PGDATABASE="agent_memory"
export PGUSER="bridge_worker"
export PGPASSWORD="your-bridge-worker-password"
export HEALTH_URL="http://127.0.0.1:8099"

bash scripts/smoke_sea_bridge.sh
```

### Running from Home Assistant Terminal

SSH to Home Assistant (system SSH, port 22222), then exec into the add-on
container:

```bash
docker exec -it addon_agent_memory_ledger_agent_memory_ledger bash
```

Inside the container, `psql` and `curl` are available. The `nats` CLI may not
be installed — the script will skip publish steps and only check health
endpoints and existing table data.

```bash
export NATS_URL="nats://your-nats-server:4222"
export PGHOST="/var/run/postgresql"
export PGPORT="5432"
export PGDATABASE="agent_memory"
export PGUSER="postgres"
export PGPASSWORD="homeassistant"
export HEALTH_URL="http://127.0.0.1:8099"
export PG_SUPERUSER="postgres"
export PG_SUPERPASSWORD="homeassistant"

bash /usr/share/agent_memory_ledger/smoke_sea_bridge.sh
```

Note: the script is in `scripts/` in the repository but would need to be copied
into the container image or run from a mounted volume. Alternatively, run it
from your dev machine pointing to the HA host's PostgreSQL port (if exposed).

### Exit Codes

| Code | Meaning                   |
| ---- | ------------------------- |
| 0    | All checks passed         |
| 1    | One or more checks failed |

### Cleanup

The script prints cleanup SQL at the end. To remove all smoke-test data
manually:

```sql
DELETE FROM governance.action_requests
  WHERE requesting_identity_id = '<test_identity_id>';
DELETE FROM governance.identities
  WHERE identity_id = '<test_identity_id>';
DELETE FROM event_log.agent_events
  WHERE source_agent LIKE 'smoke-%';
DELETE FROM event_log.inbox_events
  WHERE message_id LIKE 'smoke-%';
```

## Cross-Platform Builds

- Install QEMU emulation: `docker run --privileged --rm tonistiigi/binfmt --install all`
- Create a buildx builder: `docker buildx create --use --name mybuilder && docker buildx inspect mybuilder --bootstrap`

## The Easy Way

Run `./project.sh` in the root of the project to build / debug / run the addon during development.

Commands:

- `build` — build the addon for the current architecture (see PLATFORM in the file), tag as `dev`, and push to GHCR.
- `build-ha` — use the Home Assistant builder to build all architectures and push to GHCR with tag `latest`.
- `run-hassos` — build for current architecture, tag as `dev`, push to GHCR, SSH to Home Assistant, and pull the image.
- `inspect` — build for current architecture, tag as `dev`, and run locally with an interactive shell (`/bin/ash`).
- `debug` — build for current architecture, tag as `dev`, and run locally with normal startup.

## The Manual Way

To build the latest version using local docker:

```bash
docker build --platform linux/aarch64 --tag ghcr.io/godspeedai/agent-memory-ledger/aarch64:dev .
```

The Dockerfile contains default build arguments:

```dockerfile
ARG BUILD_FROM=ghcr.io/hassio-addons/base/aarch64:14.0.2
ARG BUILD_ARCH=aarch64
```

Push to GHCR for testing:

```bash
docker image push ghcr.io/godspeedai/agent-memory-ledger/aarch64:dev
```

## Build Using Home Assistant Builder

For `aarch64`:

```bash
docker run --rm --privileged \
  -v ~/.docker:/root/.docker \
  -v ~/hassos-addon-agent-memory-ledger/agent_memory_ledger:/data \
  homeassistant/amd64-builder \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  --target agent_memory_ledger --aarch64 -t /data
```

With Codenotary CAS signing:

```bash
docker run --rm --privileged \
  --env CAS_API_KEY=$CAS_API_KEY \
  -v ~/.docker:/root/.docker \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v ~/hassos-addon-agent-memory-ledger/agent_memory_ledger:/data \
  homeassistant/amd64-builder \
  --target agent_memory_ledger --aarch64 -t /data
```

Use `--all` instead of `--aarch64` to build all architectures defined in `config.yaml`.

## Pull and Run on Home Assistant

SSH to Home Assistant (system SSH, port 22222):

```bash
# Pull the dev image
docker image pull ghcr.io/godspeedai/agent-memory-ledger/aarch64:dev

# Run with interactive shell
docker run -it --entrypoint "/bin/sh" \
  -v /mnt/data/supervisor/addons/data/local_agent_memory_ledger/:/data:rw \
  ghcr.io/godspeedai/agent-memory-ledger/aarch64:dev

# Attach to a running container
docker exec -it addon_local_agent_memory_ledger bash
```

## Dependency Management

### Overview

All Docker image tags, Python packages, and build tool versions are pinned for
reproducible builds. Renovate creates PRs to update them. A CI gate
(`lint-dockerfile-deps`) enforces the pinning policy on every push and PR.

### Pinned Dependency Locations

| Dependency                | Where pinned                                                                           | Notes                                                           |
| ------------------------- | -------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Home Assistant base image | `build.yaml`, `Dockerfile` ARG                                                         | Renovate manages via docker datasource                          |
| TimescaleDB               | `Dockerfile` FROM lines, `docker-dependencies/*`                                       | All pinned to `2.26.4-pgNN`. Renovate groups into `timescaledb` |
| PostGIS                   | `docker-dependencies/postgis-pg*`, `dependencies.yaml` matrix                          | Version passed as `VERSION` build arg                           |
| pgAgent                   | `docker-dependencies/pgagent-pg*`, `dependencies.yaml` matrix                          | Git tag checkout                                                |
| TimescaleDB Toolkit       | `docker-dependencies/timescaledb-toolkit-pg*`, `dependencies.yaml` matrix              | Git tag checkout                                                |
| System Stats              | `docker-dependencies/postgresql-extension-system-stat-pg*`, `dependencies.yaml` matrix | Git tag checkout                                                |
| RuVector                  | `docker-dependencies/ruvector-pg17`, `dependencies.yaml`                               | Git tag checkout                                                |
| Rust (RuVector builder)   | `docker-dependencies/ruvector-pg17` FROM line                                          | Pinned to `1.87.0-slim-bookworm`                                |
| Go (timescaledb-tools)    | `docker-dependencies/timescaledb-tools` ARG                                            | Pinned to `1.24.4`                                              |
| cargo-pgrx                | `docker-dependencies/*-toolkit-*`, `docker-dependencies/ruvector-pg17`                 | Pinned per Dockerfile                                           |
| Oxigraph                  | `Dockerfile` ARG + SHA256 checksums                                                    | Pinned version with integrity check                             |
| Python (bridge worker)    | `requirements-bridge.txt`                                                              | Exact `==` pins required by CI                                  |
| Alpine packages           | `Dockerfile` apk add                                                                   | Floating (Alpine repo pins)                                     |

### Approved Exceptions

| Exception           | Location                                    | Rationale                                                                                                                                     |
| ------------------- | ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `:latest` tag       | `Dockerfile` line 17 (timescaledb-tools)    | Upstream has no versioned releases. Tools are rebuilt from HEAD on every dependencies workflow run.                                           |
| `:latest` tag       | `docker-dependencies/timescaledb-tools` ARG | Same as above — `go install @latest`                                                                                                          |
| `--allow-untrusted` | `Dockerfile` line 143                       | Alpine v3.23 community repo is unsigned. Package `gdal-driver-postgisraster` is only available there. Repo URL is pinned to v3.23 (not edge). |

These exceptions are registered in `scripts/check-dockerfile-deps.sh`
(`APPROVED_LATEST` array) and will not cause CI failures.

### How to Update a Dependency

#### Docker Image Dependency (e.g., TimescaleDB)

1. Update the version in **both** places:
   - `agent_memory_ledger/Dockerfile` — the `FROM timescale/timescaledb:VERSION-pgNN` lines
   - `agent_memory_ledger/docker-dependencies/*` — all files that start with `FROM timescale/timescaledb:VERSION-pgNN`
2. Update the version in `.github/workflows/dependencies.yaml` matrix if applicable.
3. Run `bash scripts/check-dockerfile-deps.sh` locally to verify.
4. Push to a branch and verify CI passes (including `lint-dockerfile-deps` job).
5. Merge. The `Dependencies` workflow will rebuild and publish the pre-built images.
6. After dependency images are published, the `Deploy` workflow will rebuild the addon.

Or: let Renovate create the PR. It groups TimescaleDB updates so all files are
updated in one PR.

#### Python Dependency (Bridge Worker)

1. Edit `agent_memory_ledger/requirements-bridge.txt`.
2. Use exact pin syntax: `package==X.Y.Z`.
3. Run `bash scripts/check-dockerfile-deps.sh` to verify.
4. Test locally if possible: `pip install -r agent_memory_ledger/requirements-bridge.txt`.

Or: let Renovate create the PR. It is configured to pin and auto-merge
minor/patch updates.

#### Adding a New `:latest` or `--allow-untrusted` Exception

1. Add a justification comment directly above the line in the Dockerfile.
2. Add the `file:line` to the `APPROVED_LATEST` array in
   `scripts/check-dockerfile-deps.sh`.
3. Document the exception in the "Approved exceptions" table above.

### CI Enforcement

The `lint-dockerfile-deps` CI job runs `scripts/check-dockerfile-deps.sh` on
every push and PR. It fails if:

- A Dockerfile contains `:latest` not listed in the approved exceptions.
- A Dockerfile contains `--allow-untrusted` without a preceding justification
  comment (within 10 lines).
- `requirements-bridge.txt` has a non-comment line without an exact `==` pin.

## SEA Forge Bridge Development

The bridge worker (`sea_nats_bridge.py`) is a Python async service that
connects PostgreSQL to NATS JetStream. Key development notes:

- Uses `nats-py==2.10.0` and `psycopg[binary]==3.2.9` (pinned in
  `requirements-bridge.txt`)
- `bridge_worker` DB role with least-privilege grants
- Inbound: pull consumer on JetStream durable
- Outbound: poll `event_log.outbox_events WHERE status='pending'` with
  `FOR UPDATE SKIP LOCKED`
- Dead letter: publish to `sea.ledger.deadletter` via core NATS
- Two-stage contract validation: envelope then subject-specific payload
- Subject routing with fail-closed/fail-open semantics

### Key API Notes

- `add_stream()` / `add_consumer()` — NOT `create_stream()` / `create_consumer()`
- `reconnect_time_wait` — NOT `reconnect_wait`
- Pull consumer: `sub = await js.pull_subscribe()` then `msgs = await sub.fetch()`
- psycopg returns JSONB as `dict` (auto-deserialized), not `str`
- `js.publish()` raises `NoStreamResponseError` when subject not in stream

### Event Contract

The bridge validates inbound messages against JSON Schema files in
`rootfs/usr/share/agent_memory_ledger/contracts/`. See
`docs/SEA_EVENT_CONTRACT.md` for the full contract specification and
`docs/TELEMETRY_INTEGRATION.md` for details on message ID resolution, deduplication, and database actuators for the memory lifecycle.

When modifying the contract:

1. Update the JSON Schema files.
2. Update the corresponding tests in `tests/test_envelope_validation.py`.
3. Verify with `python -m pytest tests/test_envelope_validation.py -v`.
