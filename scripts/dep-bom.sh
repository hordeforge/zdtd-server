#!/usr/bin/env bash
# Print the dependency bill of materials from build.zig.zon, one
# `dep_<name>=<hash>` line per direct dependency.
# Single source of truth for the BOM read: `make release` writes these lines
# into buildinfo.txt and scripts/smoke-release.sh verifies every one of them is
# present, so adding a dependency cannot silently drop it from the shipped
# artifact's inventory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# A dependency is a block with both .url and .hash. Matching on the .url keeps a
# .hash line that belongs to some other block (.paths and friends) from being
# attributed to the dependency named by the previous block.
bom="$(awk '
  /^[[:space:]]*\.[A-Za-z_][A-Za-z0-9_]* = \.\{/ { name = $1; sub(/^\./, "", name); url = 0 }
  /^[[:space:]]*\.url = "/ { url = 1 }
  url && /^[[:space:]]*\.hash = "/ {
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
# Stable order so buildinfo.txt is identical across hosts for the same zon.
printf '%s\n' "$bom" | LC_ALL=C sort
