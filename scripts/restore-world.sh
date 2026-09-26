#!/usr/bin/env bash
# Restore a zdtd world_dir from a backup directory created by backup-world.sh.
# Protects against incomplete restores, accidental overwrites, and failure domains.
# See docs/subsystems/persistence.md.
#
# Usage:
#   scripts/restore-world.sh <backup_dir> <target_world_dir> [--force]
# Exit non-zero on any failure (missing backup, target conflict without --force, copy error).

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <backup_dir> <target_world_dir> [--force]" >&2
  exit 2
fi

FORCE=false
if [[ $# -eq 3 ]]; then
  if [[ "$3" == "--force" ]]; then
    FORCE=true
  else
    echo "zdtd: unknown option '$3' (expected --force)" >&2
    exit 2
  fi
fi

if [[ ! -d "$1" ]]; then
  echo "zdtd: backup_dir not a directory: $1" >&2
  exit 1
fi
BACKUP_DIR=$(cd -- "$1" && pwd)

# Fail closed if backup_dir contains no files.
backup_file_count=$(find "$BACKUP_DIR" -type f | wc -l)
if [[ "$backup_file_count" -lt 1 ]]; then
  echo "zdtd: backup_dir contains zero files: $BACKUP_DIR" >&2
  exit 1
fi

TARGET_PARENT_RAW=$(dirname -- "$2")
mkdir -p -- "$TARGET_PARENT_RAW"
TARGET_PARENT=$(cd -- "$TARGET_PARENT_RAW" && pwd)
TARGET_BASE=$(basename -- "$2")
TARGET_WORLD_DIR="$TARGET_PARENT/$TARGET_BASE"

# Refuse self-restore or nested restore.
case "$BACKUP_DIR" in
  "$TARGET_WORLD_DIR"|"$TARGET_WORLD_DIR"/*)
    echo "zdtd: backup_dir must not be inside target_world_dir ($TARGET_WORLD_DIR)" >&2
    exit 2
    ;;
  *)
    ;;
esac

case "$TARGET_WORLD_DIR" in
  "$BACKUP_DIR"/*)
    echo "zdtd: target_world_dir must not be inside backup_dir ($BACKUP_DIR)" >&2
    exit 2
    ;;
  *)
    ;;
esac

# Check existing target.
PRERESTORE=""
if [[ -d "$TARGET_WORLD_DIR" ]]; then
  target_file_count=$(find "$TARGET_WORLD_DIR" -type f | wc -l)
  if [[ "$target_file_count" -gt 0 ]]; then
    if [[ "$FORCE" == "true" ]]; then
      STAMP=$(date -u +%Y%m%dT%H%M%SZ)
      PRERESTORE="${TARGET_WORLD_DIR}.prerestore.${STAMP}.$$"
      mv -- "$TARGET_WORLD_DIR" "$PRERESTORE"
      echo "zdtd: preserved prior target state at $PRERESTORE"
    else
      echo "zdtd: target_world_dir exists and contains $target_file_count files: $TARGET_WORLD_DIR" >&2
      echo "zdtd: pass --force to replace target (a pre-restore safety copy will be preserved)" >&2
      exit 1
    fi
  fi
fi

STAGE="${TARGET_WORLD_DIR}.staging.$$"
rm -rf -- "$STAGE"
mkdir -p -- "$STAGE"
trap 'rm -rf -- "$STAGE"' EXIT INT TERM

if ! cp -a -- "$BACKUP_DIR"/. "$STAGE"/ 2>/dev/null; then
  cp -R -- "$BACKUP_DIR"/. "$STAGE"/
fi

restored_file_count=$(find "$STAGE" -type f | wc -l)
if [[ "$restored_file_count" -lt 1 ]]; then
  rm -rf -- "$STAGE"
  if [[ -n "$PRERESTORE" && -d "$PRERESTORE" ]]; then
    mv -- "$PRERESTORE" "$TARGET_WORLD_DIR"
  fi
  echo "zdtd: restore produced zero files from $BACKUP_DIR" >&2
  exit 1
fi

mv -- "$STAGE" "$TARGET_WORLD_DIR"
trap - EXIT INT TERM

echo "zdtd: restored $TARGET_WORLD_DIR ($restored_file_count files from $BACKUP_DIR)"
if [[ -n "$PRERESTORE" ]]; then
  echo "zdtd: prior world preserved at $PRERESTORE"
fi
