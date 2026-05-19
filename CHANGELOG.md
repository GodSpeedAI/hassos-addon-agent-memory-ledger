<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

This changelog was introduced after earlier tagged releases, so pre-0.3.0 history may be backfilled incrementally.

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
