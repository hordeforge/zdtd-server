#!/usr/bin/env bash
# Compile the webui TypeScript sources (src/server/webui/ts) and splice the
# emitted JS into the committed pages between their `/* zdtd-ts:<page> */`
# markers. Run this after editing a .ts source and commit the regenerated
# pages; `make lint` fails when the committed pages are stale.
#
# tsc runs through bunx pinned by TSC_VERSION (same convention as oxlint; the
# repo does not track package.json/node_modules). `zig build` never invokes
# this script: the pages ship with the compiled JS inline (ADR 0018), so the
# Zig build stays pure and offline.
# Override locally: TSC_VERSION=5.9.3 bash scripts/build-webui-ts.sh
#
# Usage: scripts/build-webui-ts.sh [--dest DIR]   (default: src/server/webui)
#
# Requires: bun (bunx), python3 (already a make check requirement).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tsc_version="${TSC_VERSION:-5.9.3}"
ts_dir="$root/src/server/webui/ts"
dest="$root/src/server/webui"
if [ "${1:-}" = "--dest" ]; then
  dest="$2"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Emit one classic script .js per source into $tmp (tsconfig: module none).
bunx -p "typescript@$tsc_version" tsc -p "$ts_dir/tsconfig.json" --outDir "$tmp"

python3 - "$tmp" "$dest" <<'PY'
import pathlib
import re
import sys

js_dir, html_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

# Compiled file per marker name; login.html and login_failed.html share login.js.
MARKER_JS = {
    "login": "login.js",
    "lockout": "lockout.js",
    "shell": "shell.js",
}

MARK = re.compile(r"/\* zdtd-ts:([A-Za-z0-9_-]+) \*/.*?/\* /zdtd-ts:\1 \*/", re.DOTALL)

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

    out, n = MARK.subn(splice, text)
    if n == 0:
        raise SystemExit(f"build-webui-ts: no zdtd-ts markers found in {html_path}")
    if out != text:
        html_path.write_text(out, encoding="utf-8")
        changed += 1

if changed:
    print(f"zdtd: build-webui-ts: regenerated {changed} page(s) in {html_dir}")
PY
