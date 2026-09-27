#!/usr/bin/env bash
# Compile the webui TypeScript sources (src/server/webui/ts) and splice the
# emitted JS into the committed pages between their `/* zdtd-ts:<page> */`
# markers. Run this after editing a .ts/.tsx source and commit the regenerated
# pages; `make lint` fails when the committed pages are stale.
#
# Styling is Tailwind v4: markup in the .html/.tsx carries utilities, the
# theme (design tokens) lives in src/server/webui/webui.css (@theme), and this
# script builds that entry with the cached @tailwindcss/cli (staged by
# scripts/webui-ts-project.sh; no package.json/node_modules in the tree) and
# splices the output into the pages between the zdtd-css markers. The Zig
# build stays pure and offline: pages ship the compiled CSS inline.
# Override locally: PREACT_VERSION=10.29.8 TAILWIND_VERSION=4.3.3 bash scripts/build-webui-ts.sh
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

# Tailwind: compile one CSS bundle per page entry. Each webui-<page>.css
# declares its own @source set, so a page ships only the utilities it uses
# (the login pages stay small instead of carrying the dashboard's chart and
# table utilities). Theme (@theme in webui.css) rides along in each output.
for page in shell login lockout; do
  ( cd "$project" && bunx --bun @tailwindcss/cli \
    -i "$project/webui-$page.css" -o "$tmp/webui-$page.css" --minify )
done

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

python3 - "$tmp" "$dest" <<'PY'
import pathlib
import re
import sys

js_dir, html_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
PAGE_CSS = {
    "shell.html": "webui-shell.css",
    "login.html": "webui-login.css",
    "login_lockout.html": "webui-lockout.css",
}

# Compiled bundle per marker name.
MARKER_JS = {
    "login": "login.js",
    "lockout": "lockout.js",
    "shell": "shell.js",
}

MARK = re.compile(r"/\* zdtd-ts:([A-Za-z0-9_-]+) \*/.*?/\* /zdtd-ts:\1 \*/", re.DOTALL)
CSS_MARK = re.compile(r"/\* zdtd-css:([a-z0-9-]+) \*/.*?/\* /zdtd-css:\1 \*/", re.DOTALL)

# The Tailwind build is the whole page stylesheet: every zdtd-css region
# marker in a page is replaced by that page's compiled bundle. The region name
# is a label for humans reading the marker; one page carries one region.
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

    page_css_file = PAGE_CSS.get(html_path.name)
    if page_css_file is None:
        raise SystemExit(f"build-webui-ts: no Tailwind bundle for {html_path.name}")
    page_css = (js_dir / page_css_file).read_text(encoding="utf-8").rstrip("\n")

    def splice_css(m):
        name = m.group(1)
        return f"/* zdtd-css:{name} */\n{page_css}\n/* /zdtd-css:{name} */"

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
