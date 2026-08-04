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

# Domain and encoding packages follow the dependency notes in their root modules.
check_edges assets 'server|wire|world|litenet|apm'
check_edges ecs 'server|wire|world|litenet|apm'
check_edges world 'server|wire|litenet|apm'
check_edges wire 'server|litenet|apm'

if [[ $fail -ne 0 ]]; then
  echo "lint-architecture: forbidden package dependency (see src/*/root.zig)" >&2
  exit 1
fi

echo "lint-architecture: clean"
