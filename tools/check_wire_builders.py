#!/usr/bin/env python3
"""Every `pub fn build*Body` in src/wire must be referenced somewhere in src.

A stock body builder that nothing calls is either dead code or a wire path that
was never wired up - both are the kind of gap this project treats as a defect
(`src/wire` is the contract the stock client reads). Re-exports through
`packages.zig` count as references, which is correct: the facade is how callers
reach the builder.

Baseline 2026-10-03: 135 builders, 0 unreferenced.
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WIRE = os.path.join(ROOT, "src", "wire")
SRC = os.path.join(ROOT, "src")

BUILDER = re.compile(r"pub fn (build[A-Za-z0-9_]*)\(")


def zig_files(path: str) -> list[str]:
    out = []
    for dirpath, _dirs, names in os.walk(path):
        for n in names:
            if n.endswith(".zig"):
                out.append(os.path.join(dirpath, n))
    return out


def main() -> int:
    # name -> defining file (a name defined twice is itself a finding).
    defined: dict[str, str] = {}
    dupes: list[str] = []
    for path in zig_files(WIRE):
        text = open(path, errors="ignore").read()
        # Skip the test blocks: a builder defined only in a test is not the wire.
        for m in BUILDER.finditer(text):
            name = m.group(1)
            if name in defined:
                dupes.append(f"{name} in {os.path.relpath(path, ROOT)} and {os.path.relpath(defined[name], ROOT)}")
            defined[name] = path

    sources = {p: open(p, errors="ignore").read() for p in zig_files(SRC)}

    unreferenced: list[str] = []
    for name, path in sorted(defined.items()):
        found = False
        for q, text in sources.items():
            count = text.count(name)
            if q == path:
                count -= 1  # the definition line itself
            if count > 0:
                found = True
                break
        if not found:
            unreferenced.append(f"{name} ({os.path.relpath(path, ROOT)})")

    if dupes:
        print(f"FAIL: duplicate wire builder names ({len(dupes)}):", file=sys.stderr)
        for d in dupes:
            print("  " + d, file=sys.stderr)
    if unreferenced:
        print(f"FAIL: wire builders nothing calls ({len(unreferenced)}):", file=sys.stderr)
        for u in unreferenced:
            print("  " + u, file=sys.stderr)
    if dupes or unreferenced:
        return 1

    print(f"wire builders: {len(defined)} defined, all referenced")
    return 0


if __name__ == "__main__":
    sys.exit(main())
