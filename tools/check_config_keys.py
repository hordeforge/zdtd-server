#!/usr/bin/env python3
"""Config-surface gate: every zdtd.toml key is documented and templated.

`src/server/zdtd_config.zig` is the single zdtd.toml parser, and the binder
walks the section structs, so adding a field there silently adds an operator
key. That key is only discoverable if it also lands in the shipped template
(`zdtd.toml.example`, copied into the release by the Makefile) and in the key
table (`docs/GAME_OPTIONS.md`). This check fails when one of the three drifts.

Exit status is 1 with a printed report when a key is missing.

Usage: python3 tools/check_config_keys.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Section structs the TOML binder walks. `Plugin` is excluded: its fields are
# module paths and budgets that the [plugin] block documents as prose.
SECTIONS = ("Stream", "Authority", "Feature", "Perf", "Sim", "Apm", "Worldgen")

STRUCT_RE = re.compile(r"^pub const (\w+) = struct \{")
FIELD_RE = re.compile(r"^    ([a-z_][a-z0-9_]*): ")


def repo_root() -> Path:
    here = Path(__file__).resolve()
    for d in here.parents:
        if (d / "build.zig.zon").is_file():
            return d
    msg = "check_config_keys: no build.zig.zon above this script"
    raise SystemExit(msg)


def section_keys(src: str) -> dict[str, list[str]]:
    """Field names per section struct, in declaration order."""
    out: dict[str, list[str]] = {}
    current: str | None = None
    for line in src.splitlines():
        m = STRUCT_RE.match(line)
        if m:
            current = m.group(1) if m.group(1) in SECTIONS else None
            if current:
                out[current] = []
            continue
        if current is None:
            continue
        if line.startswith("};"):
            current = None
            continue
        f = FIELD_RE.match(line)
        if f:
            out[current].append(f.group(1))
    return out


def main() -> int:
    root = repo_root()
    keys = section_keys((root / "src/server/zdtd_config.zig").read_text())
    missing_sections = [s for s in SECTIONS if s not in keys]
    if missing_sections:
        print(
            "check_config_keys: section struct(s) not found in "
            f"zdtd_config.zig: {', '.join(missing_sections)}"
        )
        return 1

    template = (root / "zdtd.toml.example").read_text()
    options = (root / "docs/GAME_OPTIONS.md").read_text()
    # A key counts as present when it appears as a whole word: the template
    # lists most keys commented out, and GAME_OPTIONS names them in prose.
    failures: list[str] = []
    for section, fields in keys.items():
        for key in fields:
            word = re.compile(rf"\b{re.escape(key)}\b")
            if not word.search(template):
                failures.append(f"{section}.{key}: missing from zdtd.toml.example")
            if not word.search(options):
                failures.append(f"{section}.{key}: missing from docs/GAME_OPTIONS.md")

    if failures:
        print("check_config_keys: zdtd.toml keys not discoverable by operators:")
        for f in failures:
            print(f"  {f}")
        print(
            "Add the key to zdtd.toml.example (commented, with its default) "
            "and to the matching docs/GAME_OPTIONS.md row."
        )
        return 1

    total = sum(len(v) for v in keys.values())
    print(f"check_config_keys: {total} zdtd.toml keys documented and templated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
