"""Shared utilities for skill-creator scripts."""

from pathlib import Path

import yaml


def parse_skill_md(skill_path: Path) -> tuple[str, str, str]:
    """Parse a SKILL.md file, returning (name, description, full_content)."""
    content = (skill_path / "SKILL.md").read_text(encoding="utf-8")
    lines = content.splitlines()

    if lines[0].strip() != "---":
        raise ValueError("SKILL.md missing frontmatter (no opening ---)")

    end_idx = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            end_idx = i
            break

    if end_idx is None:
        raise ValueError("SKILL.md missing frontmatter (no closing ---)")

    # Extract frontmatter block and parse with YAML
    frontmatter_block = "\n".join(lines[1:end_idx])
    try:
        frontmatter = yaml.safe_load(frontmatter_block)
        if not isinstance(frontmatter, dict):
            frontmatter = {}
    except yaml.YAMLError as e:
        raise ValueError(f"SKILL.md frontmatter is invalid YAML: {e}")

    name = frontmatter.get("name", "").strip()
    description = frontmatter.get("description", "").strip()

    if not name or not isinstance(name, str):
        raise ValueError("SKILL.md frontmatter missing or invalid 'name' field")
    if not description or not isinstance(description, str):
        raise ValueError("SKILL.md frontmatter missing or invalid 'description' field")

    return name, description, content
