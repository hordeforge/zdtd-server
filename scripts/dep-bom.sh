#!/usr/bin/env bash
# Print the dependency bill of materials from build.zig.zon, one
# `dep_<name>=<hash>` line per direct dependency.
# Single source of truth for the BOM read: `make release` writes these lines
# into buildinfo.txt and scripts/smoke-release.sh verifies every one of them is
# present, so adding a dependency cannot silently drop it from the shipped
# artifact's inventory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bom="$(awk '
  /^[[:space:]]*\.[A-Za-z_][A-Za-z0-9_]* = \.\{/ { name = $1; sub(/^\./, "", name) }
  /^[[:space:]]*\.hash = "/ {
    hash = $0
    sub(/^[^"]*"/, "", hash)
    sub(/".*$/, "", hash)
    print "dep_" name "=" hash
  }
' "$ROOT/build.zig.zon")"
if [[ -z "$bom" ]]; then
  echo "dep-bom: no dependency hashes found in build.zig.zon" >&2
  exit 1
fi
printf '%s\n' "$bom"
