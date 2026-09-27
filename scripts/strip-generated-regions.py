#!/usr/bin/env python3
"""Copy a webui page with its generated regions emptied.

Usage: scripts/strip-generated-regions.py SRC DST

`scripts/build-webui-ts.sh` splices the compiled Tailwind CSS and the bundled
page JS between the `zdtd-css:<region>` / `zdtd-ts:<name>` markers in the
committed pages. `scripts/webui-ts-project.sh` stages those pages next to the
Tailwind entry so the scanner sees the authored static markup, but the
scanner reads class-shaped tokens anywhere in a file: a compiled
`.transition-colors{...}` rule would re-generate its own utility on every
build, so a rule stays in the output after the source that used it is gone.

Blanking the generated regions on the staged copy keeps the scanner reading
only authored markup. The committed pages are never touched.

Part of `make lint`/`make webui-ts`; requires python3.
"""

import pathlib
import re
import sys

REGION = re.compile(
    r"/\* zdtd-(?:css|ts):[A-Za-z0-9_-]+ \*/.*?/\* /zdtd-(?:css|ts):[A-Za-z0-9_-]+ \*/",
    re.DOTALL,
)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} SRC DST", file=sys.stderr)
        return 2
    src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    dst.write_text(REGION.sub("/* generated: stripped for the Tailwind scan */", src.read_text(encoding="utf-8")), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
