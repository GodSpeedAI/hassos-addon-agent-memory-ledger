#!/usr/bin/env python3
"""Validate dependency Dockerfiles for BuildKit mount typos."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEPENDENCIES = ROOT / "agent_memory_ledger" / "docker-dependencies"
MOUNT_RE = re.compile(r"--mount=type=([^,\\\s]+)")
ALLOWED_TYPES = {
    "bind",
    "cache",
    "secret",
    "ssh",
    "tmpfs",
}


def main() -> None:
    errors: list[str] = []
    for path in sorted(DEPENDENCIES.iterdir()):
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        for match in MOUNT_RE.finditer(text):
            mount_type = match.group(1)
            if mount_type not in ALLOWED_TYPES:
                errors.append(f"{path.relative_to(ROOT)} uses unsupported BuildKit mount type: {mount_type}")

    if errors:
        raise AssertionError("\n".join(errors))


if __name__ == "__main__":
    main()
