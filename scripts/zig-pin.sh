#!/usr/bin/env bash
# Print the exact pinned Zig compiler version from .zigversion.
# Single source of truth for the toolchain pin read: scripts/check-release.sh
# and the CI workflow steps all go through this script, so the pin format
# lives in one place and cannot drift between local gates and CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pin="$(tr -d '[:space:]' < "$ROOT/.zigversion")"
if [[ -z "$pin" ]]; then
  echo "zig-pin: .zigversion is empty" >&2
  exit 1
fi
printf '%s\n' "$pin"
