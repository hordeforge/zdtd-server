#!/usr/bin/env bash
# lint-cycles.sh - fail on any import cycle that is not fully inside
# src/server/ (the documented Game <-> game/* and Game <-> c2s delegation is
# allowed; every other package must be a strict DAG).
#
# Method: DFS over @import edges with an on-stack mark. Package edges are
# collected recursively from every Zig source in src/<pkg>/ so leaf imports
# cannot bypass the cycle check.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v rg >/dev/null 2>&1; then
  echo "lint-cycles: missing required tool: rg (ripgrep)" >&2
  exit 127
fi

declare -A EDGES

pkg_edges() {
  local pkg="$1"
  local dir="src/${pkg}"
  [[ -d "$dir" ]] || return 0
  local imports
  # The one sanctioned ecs -> assets edge (rules.zig comptime sandbox_presets
  # defaults, documented in scripts/lint-architecture.sh) is excluded so the
  # documented exception does not look like a cycle.
  imports="$(rg -o '@import\("(\.\./)+[a-z0-9_]+' "$dir" --glob '*.zig' 2>/dev/null |
    grep -v '^src/ecs/rules\.zig:@import("\.\./assets' |
    sed -E 's/.*@import\("(\.\.\/)+//' | sort -u || true)"
  for tgt in $imports; do
    tgt="${tgt%%/*}"
    if [[ "$tgt" != "$pkg" && -d "src/${tgt}" ]]; then
      EDGES["$pkg"]="${EDGES[$pkg]-} $tgt"
    fi
  done
}

pkgs=""
for d in src/*/; do
  pkg="$(basename "$d")"
  [[ -f "src/${pkg}/root.zig" ]] || continue
  pkgs="$pkgs $pkg"
done
pkgs="$pkgs protocol version"

for p in $pkgs; do
  pkg_edges "$p"
done

declare -A VISIT
declare -A STACK
cycle_found=0

dfs() {
  local node="$1"
  local trail="$2"
  if [[ "${STACK[$node]-}" == "1" ]]; then
    echo "lint-cycles: cycle involving $node (trail: $trail -> $node)" >&2
    cycle_found=1
    return
  fi
  if [[ "${VISIT[$node]-}" == "1" ]]; then
    return
  fi
  VISIT[$node]=1
  STACK[$node]=1
  local next
  for next in ${EDGES[$node]-}; do
    dfs "$next" "$trail -> $node"
  done
  STACK[$node]=0
}

# server is allowed to cycle internally (Game <-> shard delegation); mark its
# intra-server edges as visited so they do not trip the DFS.
VISIT[server]=1
for p in $pkgs; do
  [[ "$p" == "server" ]] && continue
  dfs "$p" ""
done

if [[ $cycle_found -ne 0 ]]; then
  echo "lint-cycles: non-server import cycle detected (see above)" >&2
  exit 1
fi
echo "lint-cycles: clean (all non-server packages are a strict DAG)"
