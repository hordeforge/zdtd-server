#!/usr/bin/env bash
# Enforce package dependency direction documented by each src/*/root.zig.
# ast-grep does not support Zig, so imports are checked with anchored rg patterns.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v rg >/dev/null 2>&1; then
  echo "lint-architecture: missing required tool: rg (ripgrep)" >&2
  exit 127
fi

fail=0

check_edges() {
  local package="$1"
  local forbidden="$2"
  local hits
  hits="$(rg -n --glob '*.zig' "@import\\(\"\\.\\./(${forbidden})/" "src/${package}" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits"
    fail=1
  fi
}

# Leaf and infrastructure packages cannot depend on application or domain layers.
check_edges util 'server|wire|world|ecs|assets|litenet|apm'
check_edges apm 'server|wire|world|ecs|assets|litenet'
check_edges litenet 'server|world|ecs|assets|apm'
check_edges plugin 'server|wire|world|ecs|assets|litenet|apm'

# Domain and encoding packages follow the dependency notes in their root modules.
# assets→ecs is allowed (pure shapes only: components, quest kinds).
# ecs must NOT import assets (offline fixtures live in ecs; production uses hooks).
check_edges assets 'server|wire|world|litenet|apm'
check_edges ecs 'server|wire|world|assets|litenet|apm'
check_edges world 'server|wire|litenet|apm'
check_edges wire 'server|litenet|apm'

if [[ $fail -ne 0 ]]; then
  echo "lint-architecture: forbidden package dependency (see src/*/root.zig)" >&2
  exit 1
fi

# Every package file must be referenced by its root.zig barrel, or its tests
# silently drop out of the `zig build test` aggregate.
for dir in src/*/; do
  pkg_root="${dir}root.zig"
  [[ -f "$pkg_root" ]] || continue
  for f in "$dir"*.zig; do
    base="$(basename "$f")"
    [[ "$base" == root.zig ]] && continue
    # Fixed-string match: filenames contain '.' which is a regex metacharacter.
    if ! grep -Fq "\"$base\"" "$pkg_root"; then
      echo "lint-architecture: $f not referenced in $pkg_root (tests not aggregated)" >&2
      fail=1
    fi
  done
done

# packages.zig is the stock body facade: every wire/stock_*.zig must be re-exported
# there so callers have one stable import surface (leaf files stay importable too).
if [[ -f src/wire/packages.zig ]]; then
  for f in src/wire/stock_*.zig; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    if ! grep -Fq "\"$base\"" src/wire/packages.zig; then
      echo "lint-architecture: $f not re-exported from src/wire/packages.zig (facade gap)" >&2
      fail=1
    fi
  done
fi

if [[ $fail -ne 0 ]]; then
  exit 1
fi

echo "lint-architecture: clean"
