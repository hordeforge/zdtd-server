#!/usr/bin/env bash
# Print the exact pinned Bun version from .bun-version.
# Single source of truth for the Bun pin: CI installs this version, and
# need-oxlint names it when bunx is missing, so local and CI cannot drift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pin="$(tr -d '[:space:]' < "$ROOT/.bun-version")"
if [[ -z "$pin" ]]; then
  echo "bun-pin: .bun-version is empty" >&2
  exit 1
fi
printf '%s\n' "$pin"
