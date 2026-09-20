#!/usr/bin/env bash
# Compile the webui TypeScript sources (src/server/webui/ts) and splice the
# emitted JS into the committed pages between their `/* zdtd-ts:<page> */`
# markers. Run this after editing a .ts/.tsx source and commit the regenerated
# pages; `make lint` fails when the committed pages are stale.
#
# The dashboard is a Preact app (ADR 0040): shell.tsx is JSX and imports
# `preact`, so the sources are bundled rather than emitted file-by-file.
# scripts/webui-ts-project.sh stages the pinned toolchain and dependency in a
# cache project (no package.json/node_modules in the tree); this script then
# runs `bun build --format=iife` per page entry. The bundle is what ships
# inline, so the Zig build stays pure and offline and nothing is read from disk
# at runtime (AGENTS rule 12).
# Override locally: PREACT_VERSION=10.29.8 bash scripts/build-webui-ts.sh
#
# Usage: scripts/build-webui-ts.sh [--dest DIR]   (default: src/server/webui)
#
# Requires: bun, python3.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$root/src/server/webui"
if [ "${1:-}" = "--dest" ]; then
  dest="$2"
fi

# shellcheck source=scripts/webui-ts-project.sh
. "$root/scripts/webui-ts-project.sh"
project="$(webui_ts_prepare)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Bundle one IIFE per page entry. `--define process.env.NODE_ENV` selects
# preact's production branches; --minify keeps the embedded page small (the
# readable source is the .tsx file, not the committed page).
for entry in login lockout shell; do
  input="$project/$entry.ts"
  [ -f "$input" ] || input="$project/$entry.tsx"
  bun build "$input" \
    --outfile "$tmp/$entry.js" \
    --format=iife \
    --target=browser \
    --minify \
    --define 'process.env.NODE_ENV="production"'
done

python3 - "$tmp" "$dest" "$root/src/server/webui/shared.css" <<'PY'
import pathlib
import re
import sys

js_dir, html_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
shared_css_path = pathlib.Path(sys.argv[3])

# Compiled bundle per marker name.
MARKER_JS = {
    "login": "login.js",
    "lockout": "lockout.js",
    "shell": "shell.js",
}

MARK = re.compile(r"/\* zdtd-ts:([A-Za-z0-9_-]+) \*/.*?/\* /zdtd-ts:\1 \*/", re.DOTALL)
CSS_MARK = re.compile(r"/\* zdtd-css:([a-z0-9-]+) \*/.*?/\* /zdtd-css:\1 \*/", re.DOTALL)

# The shared style sheet is the one home for the design tokens and the sign-in
# chrome. Regions are spliced by name, so a page carries only what it uses and
# the committed page stays self-contained.
css_regions = {}
for match in CSS_MARK.finditer(shared_css_path.read_text(encoding="utf-8")):
    css_regions[match.group(1)] = match.group(0)

changed = 0
for html_path in sorted(html_dir.glob("*.html")):
    text = html_path.read_text(encoding="utf-8")

    def splice(m):
        name = m.group(1)
        js = MARKER_JS.get(name)
        if js is None:
            raise SystemExit(f"build-webui-ts: no TS source for marker '{name}' in {html_path}")
        body = (js_dir / js).read_text(encoding="utf-8").rstrip("\n")
        return f"/* zdtd-ts:{name} */\n{body}\n/* /zdtd-ts:{name} */"

    def splice_css(m):
        name = m.group(1)
        region = css_regions.get(name)
        if region is None:
            raise SystemExit(
                f"build-webui-ts: no '{name}' region in {shared_css_path.name} "
                f"for the marker in {html_path.name}"
            )
        return region

    out, n = MARK.subn(splice, text)
    if n == 0:
        raise SystemExit(f"build-webui-ts: no zdtd-ts markers found in {html_path}")
    out, css_n = CSS_MARK.subn(splice_css, out)
    if css_n != out.count("/* zdtd-css:"):
        raise SystemExit(f"build-webui-ts: unclosed zdtd-css marker in {html_path}")
    if out != text:
        html_path.write_text(out, encoding="utf-8")
        changed += 1

if changed:
    print(f"zdtd: build-webui-ts: regenerated {changed} page(s) in {html_dir}")
PY
