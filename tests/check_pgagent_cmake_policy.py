#!/usr/bin/env python3
"""Ensure pgAgent dependency builds tolerate CMake 4.x policy removal."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FILES = [
    ROOT / "agent_memory_ledger" / "docker-dependencies" / "pgagent-pg16",
    ROOT / "agent_memory_ledger" / "docker-dependencies" / "pgagent-pg17",
]


def main() -> None:
    errors: list[str] = []
    for path in FILES:
        text = path.read_text(encoding="utf-8")
        if "cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ." not in text:
            errors.append(
                f"{path.relative_to(ROOT)} must pass -DCMAKE_POLICY_VERSION_MINIMUM=3.5"
            )

    if errors:
        raise AssertionError("\n".join(errors))


if __name__ == "__main__":
    main()
