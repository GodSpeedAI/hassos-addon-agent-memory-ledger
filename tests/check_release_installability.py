#!/usr/bin/env python3
"""Validate that release configuration catches private or missing add-on images."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPLOY_WORKFLOW = ROOT / ".github" / "workflows" / "deploy.yaml"
README = ROOT / "README.md"


def require_contains(path: Path, required: str) -> None:
    text = path.read_text(encoding="utf-8")
    if required not in text:
        raise AssertionError(f"{path.relative_to(ROOT)} is missing: {required}")


def main() -> None:
    require_contains(
        DEPLOY_WORKFLOW,
        "Verify anonymous image pull",
    )
    require_contains(
        DEPLOY_WORKFLOW,
        "docker manifest inspect",
    )
    require_contains(
        README,
        "The architecture images must be public in GHCR before Home Assistant can install the add-on.",
    )


if __name__ == "__main__":
    main()
