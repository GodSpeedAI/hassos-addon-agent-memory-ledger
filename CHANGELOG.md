<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

This changelog was introduced after earlier tagged releases, so pre-0.3.0 history may be backfilled incrementally.

## [0.4.1] - 2026-07-02

### Changed

- Main README de-branded: replaced product-specific "ZeroClaw" references with
  the generic "Governed Agent Runtime(s)" term. SEA Forge references retained.

### Fixed

- Dependencies workflow no longer builds arm64 dependency images under QEMU
  cross-emulation. The `publish` job (pgagent, postgis, system-stat,
  timescaledb-tools) now builds each architecture on **native runners**
  (`ubuntu-24.04-arm` for arm64) and merges them into a multi-arch manifest —
  matching the approach already used for timescaledb-toolkit and ruvector. This
  eliminates the multi-hour arm64 build path.

### Removed

- Orphan remote tags `v0.3.0`, `v0.3.1`, `v0.3.2` (tags with no published
  release and no image — their deploys had failed pre-0.4.0).

## [0.4.0] - 2026-07-02

### Fixed

- Resolved the release/deploy build failure that blocked all 0.3.x image
  publications: removed the `python3 -m ensurepip` step from the Dockerfile that
  failed under PEP 668 (`externally-managed-environment`). Bridge Python
  dependencies now install via `pip install --break-system-packages`.
- Prettier formatting failures that left CI red across `CLAUDE.md`, the SEA
  Event Contract docs, the telemetry integration guide, and the CEP-0008
  conformance reference.

### Changed

- **Deploy image tagging is now sourced from the published release tag**, not
  from `version:` in `config.yaml`. This eliminates the drift that previously
  produced mislabeled images (a release whose `config.yaml` still read
  `version: dev` tagged the image `:dev` instead of the release version).
  A pre-build guard now fails the job if the release tag and `config.yaml`
  version disagree, since Home Assistant pulls `{image}:{config_version}`.
- The `workflow_run` (Dependencies) and `workflow_dispatch` deploy triggers now
  rebuild and re-tag the **latest published release** against refreshed
  dependency images, instead of tagging whatever `config.yaml` happened to read.
  When no release exists yet, these triggers skip cleanly.
- Pinned every Docker/checkout action in `deploy.yaml` to immutable commit SHAs
  at Node.js 24-compatible releases, matching `ci.yaml`'s pinning posture and
  clearing the Node.js 20 runner deprecation.
- The publish job now builds each architecture on **native runners**
  (`ubuntu-24.04-arm` for aarch64) instead of QEMU cross-emulation, mirroring
  the CI build job. This removes a class of pathologically slow / fragile
  aarch64 builds.
- `version:` on `main` now tracks the latest released version. The previous
  practice of reverting it to `dev` between releases is unsafe for a
  pre-built-image add-on: Home Assistant reads it to select the image tag.

### Added

- `.prettierignore` now excludes local agent/editor working state (`.agents/`,
  `.omc/`, `.logs/`, `.serena/`, `.vs/`, `.venv/`, `tmp/`, caches) so generated
  and working files no longer break the Prettier CI gate.

## [0.3.2] - 2026-05-19

### Fixed

- Fixed `workflow_dispatch` parsing for the Dependencies workflow by moving matrix-based component filtering from job-level conditions to step-level conditions.

## [0.3.1] - 2026-05-19

### Changed

- Moved TimescaleDB Toolkit dependency builds from a single QEMU-backed multi-arch job to native per-architecture runners with manifest merge.
- Added workflow concurrency controls so superseded dependency and deploy runs are canceled automatically.
- Enabled pip caching in CI and Docker builds to reduce repeated Python dependency install time.
- Reduced TimescaleDB Toolkit source checkout overhead with shallow tag clones during dependency image builds.

## [0.3.0] - 2026-05-18

### Added

- Added the skill-creator evaluation and improvement loop workflow.
- Added comprehensive test coverage for recent bridge and workflow changes.

### Changed

- Improved documentation and test clarity for the release surface.

### Fixed

- Made GHCR package visibility handling non-blocking during deploy.
- Ensured published GHCR packages are promoted to public visibility after push.

## [0.1.0] - 2026-05-06

### Added

- Initial public release of the Agent Memory Ledger Home Assistant add-on.

<!-- markdownlint-enable MD024 -->
