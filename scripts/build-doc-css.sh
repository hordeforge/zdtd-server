#!/usr/bin/env bash
# Compile the provenance dashboard's Tailwind entry and splice the result into
# the generated page.
#
# docs/provenance.html is produced by scripts/gen_provenance.py (markup in
# Tailwind utilities, an empty zdtd-css:provenance region) and by this script
# (that region filled with the page's compiled CSS). It is the same two-step
# shape as the webui pages: generate the markup, compile the CSS against the
# committed page as the source, splice the result back in, and fail when the
# committed page is stale.
#
# The page stays one self-contained file that opens over file://: the compiled
# CSS is inlined, never linked. The token contract itself is not recompiled
# here; docs/provenance.css imports the one home at
# src/server/webui/webui.css (ADR 0041), so the staged tree below mirrors just
# enough of the repo layout for that relative import to resolve.
#
# Usage: scripts/build-doc-css.sh [--dest DIR]   (default: docs)
#
# Requires: bun, python3.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$root/docs"
if [ "${1:-}" = "--dest" ]; then
  dest="$2"
fi

# shellcheck source=scripts/webui-ts-project.sh
. "$root/scripts/webui-ts-project.sh"
project="$(webui_ts_prepare)"

# The stage lives under the project so `@import "tailwindcss"` inside the
# theme resolves the pinned install by walking up to $project/node_modules.
stage="$project/doc-css-stage"
rm -rf "$stage"
mkdir -p "$stage/docs" "$stage/src/server/webui"
trap 'rm -rf "$stage"' EXIT

# Mirror the two paths the entry names: the page beside the entry, and the
# theme it imports. The scanner reads class-shaped tokens anywhere in a file, so
# the generated regions are blanked on the staged page copy; otherwise a
# compiled rule would regenerate its own utility forever.
cp "$root/docs/provenance.css" "$stage/docs/provenance.css"
cp "$root/src/server/webui/webui.css" "$stage/src/server/webui/webui.css"
python3 "$root/scripts/strip-generated-regions.py" "$dest/provenance.html" "$stage/docs/provenance.html"

# Run from the staged project so the pinned @tailwindcss/cli resolves. Tailwind
# resolves @import and @source relative to the entry file, not the cwd.
( cd "$project" && bunx --bun "@tailwindcss/cli@$webui_ts_tailwind_version" -i "$stage/docs/provenance.css" -o "$stage/provenance.out.css" --minify )

python3 - "$stage/provenance.out.css" "$dest/provenance.html" <<'PY'
import pathlib
import re
import sys

compiled = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").rstrip("\n")
page = pathlib.Path(sys.argv[2])
text = page.read_text(encoding="utf-8")
REGION = re.compile(r"/\* zdtd-css:provenance \*/.*?/\* /zdtd-css:provenance \*/", re.S)
out, n = REGION.subn(
    lambda _m: f"/* zdtd-css:provenance */\n{compiled}\n/* /zdtd-css:provenance */", text
)
if n != 1:
    raise SystemExit(f"build-doc-css: expected one zdtd-css:provenance region in {page}, found {n}")

# A utility the theme cannot generate compiles to nothing, so a typo would drop
# a style with no error anywhere. Fail instead, and name the class. The fix is
# a token the contract declares or a utility on Tailwind's scale, not a
# data-attribute hook: state rides data-state so nothing here needs a class the
# stylesheet does not know.
def escape(cls):
    return re.sub(r"([:.\[\]()%#,!'\"/+~=&$|])", r"\\\1", cls)

body = out[: out.index("/* zdtd-css:provenance */")] + out[out.index("/* /zdtd-css:provenance */") :]
used = {c for m in re.finditer(r'class="([^"]*)"', body) for c in m.group(1).split()}
unknown = [c for c in sorted(used) if "." + escape(c) not in compiled]
if unknown:
    raise SystemExit(
        "build-doc-css: classes with no generated rule (unknown token, or a "
        "class used only as a script hook - use a data attribute instead):\n  "
        + "\n  ".join(unknown)
    )

if out != text:
    page.write_text(out, encoding="utf-8")
    print(f"build-doc-css: spliced {len(compiled)} bytes of CSS into {page} ({len(used)} classes covered)")
PY
