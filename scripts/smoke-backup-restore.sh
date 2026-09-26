#!/usr/bin/env bash
# Smoke-test backup and restore tooling against a live zdtd world.
# Proves recoverability: backup generation, rotation, fail-closed guards,
# pre-restore archival, and successful daemon execution from restored data.
# Run locally or in CI: bash scripts/smoke-backup-restore.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bin="${BIN:-zig-out/bin/zdtd}"
if [[ ! -x "$bin" ]]; then
  echo "smoke-backup-restore: missing $bin (run zig build first)" >&2
  exit 1
fi

command -v timeout >/dev/null 2>&1 || {
  echo "smoke-backup-restore: missing required tool: timeout" >&2
  exit 127
}

SCRATCH="zig-out/smoke-dr"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/world" "$SCRATCH/backups" "$SCRATCH/restored"
trap 'rm -rf "$SCRATCH"' EXIT

SMOKE_PORT=27118

echo "smoke-backup-restore: 1. generating source world state with --once"
if ! timeout 15s "$bin" --port "$SMOKE_PORT" --world "$SCRATCH/world" --once >"$SCRATCH/init.log" 2>&1; then
  echo "smoke-backup-restore: failed to generate initial world state; log:" >&2
  cat "$SCRATCH/init.log" >&2 || true
  exit 1
fi
if ! grep -q 'zdtd --once complete' "$SCRATCH/init.log"; then
  echo "smoke-backup-restore: --once did not complete successfully; log:" >&2
  cat "$SCRATCH/init.log" >&2 || true
  exit 1
fi

initial_files=$(find "$SCRATCH/world" -type f | wc -l)
if [[ "$initial_files" -lt 1 ]]; then
  echo "smoke-backup-restore: initial world has no files" >&2
  exit 1
fi

echo "smoke-backup-restore: 2. creating backup"
bash scripts/backup-world.sh "$SCRATCH/world" "$SCRATCH/backups" 2 >"$SCRATCH/backup.log"

backup_item=$(find "$SCRATCH/backups" -mindepth 1 -maxdepth 1 -type d | head -n1)
if [[ -z "$backup_item" ]]; then
  echo "smoke-backup-restore: backup-world.sh produced no backup directory" >&2
  exit 1
fi

backup_files=$(find "$backup_item" -type f | wc -l)
if [[ "$backup_files" -ne "$initial_files" ]]; then
  echo "smoke-backup-restore: file count mismatch (world: $initial_files, backup: $backup_files)" >&2
  exit 1
fi

echo "smoke-backup-restore: 3. verifying unforced restore fails closed on non-empty target"
if bash scripts/restore-world.sh "$backup_item" "$SCRATCH/world" >/dev/null 2>&1; then
  echo "smoke-backup-restore: restore-world.sh without --force unexpectedly succeeded over non-empty target" >&2
  exit 1
fi

echo "smoke-backup-restore: 4. restoring to fresh target directory"
bash scripts/restore-world.sh "$backup_item" "$SCRATCH/restored" >"$SCRATCH/restore.log"

restored_files=$(find "$SCRATCH/restored" -type f | wc -l)
if [[ "$restored_files" -ne "$backup_files" ]]; then
  echo "smoke-backup-restore: restored file count mismatch ($restored_files != $backup_files)" >&2
  exit 1
fi

echo "smoke-backup-restore: 5. executing daemon on restored world"
if ! timeout 15s "$bin" --port "$SMOKE_PORT" --world "$SCRATCH/restored" --once >"$SCRATCH/restored.log" 2>&1; then
  echo "smoke-backup-restore: daemon failed to boot on restored world; log:" >&2
  cat "$SCRATCH/restored.log" >&2 || true
  exit 1
fi
if ! grep -q 'zdtd --once complete' "$SCRATCH/restored.log"; then
  echo "smoke-backup-restore: daemon --once on restored world did not complete; log:" >&2
  cat "$SCRATCH/restored.log" >&2 || true
  exit 1
fi

echo "smoke-backup-restore: 6. verifying force-restore preserves pre-restore snapshot"
bash scripts/restore-world.sh "$backup_item" "$SCRATCH/restored" --force >"$SCRATCH/force_restore.log"
prerestore_item=$(find "$SCRATCH" -maxdepth 1 -name "restored.prerestore.*" -type d | head -n1)
if [[ -z "$prerestore_item" ]]; then
  echo "smoke-backup-restore: force restore did not preserve pre-restore directory" >&2
  exit 1
fi

echo "smoke-backup-restore: ok (backup, restore safeguards, and execution verified)"
