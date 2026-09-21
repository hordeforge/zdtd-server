#!/usr/bin/env bash
# Copy a zdtd world_dir to a timestamped backup and rotate old copies.
# Atomic save (temp+rename) is not a backup: instance or disk loss needs a
# tree outside world_dir. See docs/subsystems/persistence.md.
#
# Usage:
#   scripts/backup-world.sh <world_dir> [backup_root] [keep]
# Defaults: backup_root=<world_dir>/../backups, keep=7
# Exit non-zero on any failure (missing source, copy error, empty result).

set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "usage: $0 <world_dir> [backup_root] [keep]" >&2
  exit 2
fi

KEEP=${3:-7}
if ! [[ "$KEEP" =~ ^[1-9][0-9]*$ ]]; then
  echo "zdtd: keep must be a positive integer, got '$KEEP'" >&2
  exit 2
fi

# Resolve after the existence check so a missing path prints our message
# instead of a bare `cd: ... No such file or directory` from the shell.
if [[ ! -d "$1" ]]; then
  echo "zdtd: world_dir not a directory: $1" >&2
  exit 1
fi
WORLD_DIR=$(cd -- "$1" && pwd)

if [[ $# -ge 2 && -n "${2}" ]]; then
  mkdir -p -- "$2"
  BACKUP_ROOT=$(cd -- "$2" && pwd)
else
  BACKUP_ROOT=$(cd -- "$(dirname -- "$WORLD_DIR")" && pwd)/backups
  mkdir -p -- "$BACKUP_ROOT"
fi

# Refuse to write backups inside the live world tree (same failure domain as
# a deleted world_dir and easy to clobber on restore).
case "$BACKUP_ROOT" in
  "$WORLD_DIR"|"$WORLD_DIR"/*)
    echo "zdtd: backup_root must not be inside world_dir ($WORLD_DIR)" >&2
    exit 2
    ;;
esac

BASE=$(basename -- "$WORLD_DIR")
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DEST="$BACKUP_ROOT/${BASE}-${STAMP}"
# Same-second reruns must not land inside an existing DEST (mv into dir).
if [[ -e "$DEST" ]]; then
  DEST="$BACKUP_ROOT/${BASE}-${STAMP}.$$"
fi

# Staging dir then rename so a killed copy never looks like a complete backup.
STAGE="$DEST.partial.$$"
rm -rf -- "$STAGE"
mkdir -p -- "$STAGE"
# Prefer cp -a for hardlinks-free portable trees; fall back without -a.
if ! cp -a -- "$WORLD_DIR"/. "$STAGE"/ 2>/dev/null; then
  cp -R -- "$WORLD_DIR"/. "$STAGE"/
fi

# Fail closed on empty copies (wrong path, permission, or source wiped).
file_count=$(find "$STAGE" -type f | wc -l)
if [[ "$file_count" -lt 1 ]]; then
  rm -rf -- "$STAGE"
  echo "zdtd: backup produced zero files from $WORLD_DIR" >&2
  exit 1
fi

mv -- "$STAGE" "$DEST"
echo "zdtd: backup $DEST ($file_count files)"

# Rotate: keep the newest KEEP complete backups for this world basename.
# Skip leftover `*.partial.*` staging dirs so an interrupted copy cannot
# inflate the count and rotate a finished backup out.
mapfile -t OLD < <(
  ls -1d -- "$BACKUP_ROOT/${BASE}-"* 2>/dev/null | grep -v '\.partial\.' | sort -r || true
)
if ((${#OLD[@]} > KEEP)); then
  for ((i = KEEP; i < ${#OLD[@]}; i++)); do
    rm -rf -- "${OLD[$i]}"
    echo "zdtd: rotated out ${OLD[$i]}"
  done
fi
